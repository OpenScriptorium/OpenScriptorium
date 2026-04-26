namespace :eval do
  ROLE_WEIGHTS = {
    "signature" => 1.0,
    "climax"    => 0.8,
    "quote"     => 0.7,
    "context"   => 0.5,
  }.freeze

  # Parse a Postgres array literal like {"a","b c"} to a Ruby array of strings.
  PG_ARRAY = ->(s) {
    return [] if s.nil? || s == "{}" || s == ""
    return s if s.is_a?(Array)
    s.sub(/\A\{/, "").sub(/\}\z/, "")
     .scan(/"([^"\\]*(?:\\.[^"\\]*)*)"|([^,]+)/)
     .map { |a, b| (a || b).to_s }
  }

  desc "Thematic retrieval eval: query search_concepts, measure MRR/Recall/NDCG@K"
  task :thematic, [:k] => :environment do |_, args|
    k          = (args[:k] || ENV["K"] || "10").to_i
    model_path = ENV.fetch("MODEL_PATH", Rails.root.join("tmp/embedding_model/labse_scripture").to_s)
    device     = ENV.fetch("DEVICE", "mps")
    slug       = ENV.fetch("SLUG", File.basename(model_path)).gsub(/[^a-z0-9_]/, "_")
    out_path   = ENV.fetch("OUT", Rails.root.join("tmp/eval/thematic_#{slug}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.jsonl").to_s)
    retrieve_n = (ENV["RETRIEVE_N"] || "500").to_i

    # Embedding source: where to read corpus vectors from. Defaults to the
    # original work_units.body_embedding column (current production); can be
    # pointed at a per-model side table for the model race.
    emb_table  = ENV.fetch("EMB_TABLE", "work_units")
    emb_column = ENV.fetch("EMB_COLUMN", "body_embedding")
    # Query encoding: instruction-tuned models (Qwen3) need a prompt prefix
    # only on queries. Models accept truncated dims (Matryoshka) too.
    query_prompt = ENV["QUERY_PROMPT"] # e.g. "query" for Qwen3
    query_dim    = (ENV["QUERY_DIM"] || "0").to_i

    # Allow MODEL_PATH=HuggingFace/id (no local file required)
    if File.exist?(model_path) || model_path.include?("/")
      # ok — local path or HF identifier
    else
      abort "Model not found and not HF-style: #{model_path}"
    end
    FileUtils.mkdir_p(File.dirname(out_path))

    require "open3"
    require "json"

    conn = ActiveRecord::Base.connection

    # Load concepts → relevant canonical_refs (with role weights for NDCG).
    rows = conn.select_all(<<~SQL).to_a
      SELECT c.id          AS concept_id,
             c.name        AS name,
             c.kind        AS kind,
             COALESCE(c.aliases, '{}') AS aliases,
             scv.canonical_ref_id      AS canonical_ref_id,
             scv.role                  AS role
      FROM search_concepts c
      LEFT JOIN search_concept_verses scv ON scv.search_concept_id = c.id
      ORDER BY c.id
    SQL

    concepts = {}
    rows.each do |r|
      cid = r["concept_id"]
      concepts[cid] ||= {
        id: cid, name: r["name"], kind: r["kind"],
        aliases: PG_ARRAY.call(r["aliases"]),
        relevant: {}, # canonical_ref_id => role
      }
      if r["canonical_ref_id"]
        concepts[cid][:relevant][r["canonical_ref_id"].to_i] = r["role"]
      end
    end

    # Drop concepts with no tagged verses (can't be evaluated).
    concepts = concepts.reject { |_, c| c[:relevant].empty? }
    abort "No concepts with relevant verses found" if concepts.empty?

    # Build query list: each (concept, variant) is a separate query. The "name"
    # variant gets its own row; aliases too. We compute per-concept aggregate
    # later (best-of variants and name-only).
    queries = []
    concepts.each_value do |c|
      queries << { qid: "c#{c[:id]}_name", concept_id: c[:id], variant: "name", text: c[:name] }
      c[:aliases].each_with_index do |alias_text, i|
        queries << { qid: "c#{c[:id]}_a#{i}", concept_id: c[:id], variant: "alias_#{i}", text: alias_text }
      end
    end
    queries_by_qid = queries.index_by { |q| q[:qid] }

    puts "Loaded #{concepts.size} concepts (#{queries.size} query variants)"
    puts "Encoding queries via #{model_path} on #{device}..."
    puts "  embedding source: #{emb_table}.#{emb_column}"
    puts "  query prompt: #{query_prompt || '(none)'}  query dim: #{query_dim.zero? ? 'full' : query_dim}"

    # Spawn encoder. ENCODER_SCRIPT lets us swap to the ONNX-runtime variant
    # (encode_queries_onnx.py) for testing quantized inference paths.
    venv_python = Rails.root.join("scripts/train_embeddings/venv/bin/python3").to_s
    encoder_script = ENV["ENCODER_SCRIPT"] || "scripts/eval/encode_queries.py"
    script_path = Rails.root.join(encoder_script).to_s
    if encoder_script.include?("onnx")
      cmd = [venv_python, script_path, model_path]
    else
      cmd = [venv_python, script_path, model_path, device]
      cmd += ["--prompt", query_prompt] if query_prompt
      cmd += ["--dim", query_dim.to_s] if query_dim.positive?
    end
    stdin, stdout, stderr, wait = Open3.popen3(*cmd)

    loop do
      line = stderr.gets
      break if line&.include?("ready")
      abort "Encoder failed: #{line}" if line.nil?
    end
    puts "  encoder ready"

    # Feed queries
    writer = Thread.new do
      queries.each do |q|
        stdin.puts "#{q[:qid]}\t#{q[:text].gsub(/[\n\r\t]/, ' ')}"
      end
      stdin.close
    end

    # Read query vectors → run retrieval → score
    raw = conn.raw_connection
    # Default hnsw.ef_search = 40 silently caps result count below LIMIT.
    # Raise it so retrieve_n requests can actually be filled.
    raw.exec("SET hnsw.ef_search = #{[retrieve_n * 2, 1000].max}")

    # Build the retrieval SQL once. Two cases:
    #  1) emb_table == 'work_units': vector lives on work_units directly,
    #     no join, partial index on (body_embedding IS NOT NULL).
    #  2) emb_table == 'work_unit_embeddings_<slug>': side table; JOIN to
    #     work_units on work_unit_id to fetch canonical_ref_id.
    if emb_table == "work_units"
      retrieval_sql = <<~SQL
        SELECT canonical_ref_id
        FROM work_units
        WHERE #{emb_column} IS NOT NULL
          AND canonical_ref_id IS NOT NULL
        ORDER BY #{emb_column} <=> $1::vector
        LIMIT $2
      SQL
    else
      retrieval_sql = <<~SQL
        SELECT wu.canonical_ref_id
        FROM #{emb_table} e
        JOIN work_units wu ON wu.id = e.work_unit_id
        WHERE wu.canonical_ref_id IS NOT NULL
        ORDER BY e.#{emb_column} <=> $1::vector
        LIMIT $2
      SQL
    end

    per_query_results = []
    n_done = 0

    while (line = stdout.gets)
      qid, vec_text = line.chomp.split("\t", 2)
      next unless vec_text
      q = queries_by_qid[qid]
      next unless q
      concept = concepts[q[:concept_id]]

      result = raw.exec_params(retrieval_sql, [vec_text, retrieve_n])

      seen = {}
      ranked_refs = []
      result.each do |row|
        rid = row["canonical_ref_id"].to_i
        next if seen[rid]
        seen[rid] = true
        ranked_refs << rid
      end

      ranked_refs = ranked_refs.first(100)
      relevant   = concept[:relevant]

      hits_at_k = 0
      first_hit_rank = nil
      dcg = 0.0
      ranked_refs.first(k).each_with_index do |rid, idx|
        if (role = relevant[rid])
          hits_at_k += 1
          first_hit_rank ||= idx + 1
          gain = ROLE_WEIGHTS[role] || 0.5
          dcg += gain / Math.log2(idx + 2.0)
        end
      end

      ideal_gains = relevant.values.map { |r| ROLE_WEIGHTS[r] || 0.5 }.sort.reverse.first(k)
      idcg = ideal_gains.each_with_index.sum { |g, i| g / Math.log2(i + 2.0) }

      per_query_results << {
        qid: qid,
        concept_id: q[:concept_id],
        concept_name: concept[:name],
        kind: concept[:kind],
        variant: q[:variant],
        text: q[:text],
        n_relevant: relevant.size,
        hits_at_k: hits_at_k,
        first_hit_rank: first_hit_rank,
        recall_at_k: relevant.empty? ? 0.0 : (hits_at_k.to_f / relevant.size),
        rr: first_hit_rank ? (1.0 / first_hit_rank) : 0.0,
        ndcg_at_k: idcg.zero? ? 0.0 : (dcg / idcg),
        top_k_refs: ranked_refs.first(k),
      }

      n_done += 1
      if n_done % 100 == 0
        $stdout.print "\r  scored #{n_done}/#{queries.size}"
        $stdout.flush
      end
    end

    writer.join
    wait.join
    puts "\n  scored #{n_done} queries"

    # Per-concept aggregation: best-of-variants (closest to "user phrasing wins")
    by_concept = per_query_results.group_by { |r| r[:concept_id] }
    concept_metrics = by_concept.map do |cid, results|
      best = results.max_by { |r| r[:rr] }
      name_q = results.find { |r| r[:variant] == "name" }
      {
        concept_id: cid,
        concept_name: concepts[cid][:name],
        kind: concepts[cid][:kind],
        n_relevant: concepts[cid][:relevant].size,
        n_variants: results.size,
        best_rr: best[:rr],
        best_recall: best[:recall_at_k],
        best_ndcg: best[:ndcg_at_k],
        name_rr: name_q ? name_q[:rr] : 0.0,
        name_recall: name_q ? name_q[:recall_at_k] : 0.0,
        name_ndcg: name_q ? name_q[:ndcg_at_k] : 0.0,
      }
    end

    by_kind = concept_metrics.group_by { |c| c[:kind] }

    puts
    puts "=" * 78
    puts "THEMATIC RETRIEVAL EVAL @ K=#{k}"
    puts "  Model:      #{model_path}"
    puts "  Concepts:   #{concept_metrics.size}"
    puts "  Variants:   #{queries.size}"
    puts "  Retrieved:  top-#{retrieve_n} work_units, dedupe → top-100 canonical_refs"
    puts "=" * 78
    puts

    fmt = "%-20s %6s %8s %8s %8s %8s %8s %8s"
    puts fmt % %w[kind n MRR(name) MRR(best) R@10(name) R@10(best) NDCG(name) NDCG(best)]
    puts "-" * 78

    print_row = ->(label, group) {
      n = group.size
      mrr_name = group.sum { |c| c[:name_rr] } / n
      mrr_best = group.sum { |c| c[:best_rr] } / n
      rec_name = group.sum { |c| c[:name_recall] } / n
      rec_best = group.sum { |c| c[:best_recall] } / n
      ndcg_name = group.sum { |c| c[:name_ndcg] } / n
      ndcg_best = group.sum { |c| c[:best_ndcg] } / n
      puts fmt % [label, n,
                  format("%.4f", mrr_name), format("%.4f", mrr_best),
                  format("%.4f", rec_name), format("%.4f", rec_best),
                  format("%.4f", ndcg_name), format("%.4f", ndcg_best)]
    }

    by_kind.sort_by { |kind, _| kind.to_s }.each do |kind, group|
      print_row.call(kind, group)
    end
    puts "-" * 78
    print_row.call("ALL", concept_metrics)
    puts

    # Persist
    File.open(out_path, "w") do |f|
      f.puts({
        meta: {
          model_path: model_path, device: device, k: k,
          retrieve_n: retrieve_n, ts: Time.now.iso8601,
          n_concepts: concept_metrics.size, n_queries: queries.size,
        }
      }.to_json)
      per_query_results.each { |r| f.puts(r.to_json) }
    end
    puts "Per-query results: #{out_path}"
  end

end
