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
    # current production side table (Qwen3-Embedding-0.6B, 1024d). Can be
    # pointed at any other (table, column) pair to compare model variants.
    emb_table  = ENV.fetch("EMB_TABLE", "work_unit_embeddings_qwen3_06b")
    emb_column = ENV.fetch("EMB_COLUMN", "embedding")
    # Query encoding: instruction-tuned models (Qwen3) need a prompt prefix
    # only on queries. Models accept truncated dims (Matryoshka) too.
    query_prompt = ENV["QUERY_PROMPT"] # e.g. "query" for Qwen3
    query_dim    = (ENV["QUERY_DIM"] || "0").to_i

    # Reranking: if RERANK=1, after bi-encoder retrieval take the top-K
    # candidates and re-order them with Search::Reranker (cross-encoder).
    # The eval reports BOTH numbers — bi-encoder alone and post-rerank — so
    # the lift is directly visible.
    rerank = ENV["RERANK"] == "1"
    rerank_top_k = (ENV["RERANK_TOP_K"] || "50").to_i
    rerank_instruct = ENV["RERANK_INSTRUCT"] # nil → reranker default

    # Two-pass rerank for offloading to a GPU box that doesn't have rails/DB:
    #   Pass 1 (this box):  RERANK_INPUT_OUT=tmp/eval/rerank_input.jsonl
    #     → after bi-encoder retrieval, dump (qid, query, top-K candidates)
    #     to JSONL and exit before reranking.
    #   Pass 2 (GPU box):   scripts/eval/rerank_audit_cuda.py reads the input
    #     JSONL, scores each (query, doc) pair on CUDA, writes scored JSONL.
    #   Pass 3 (this box):  RERANK_SCORES_IN=tmp/eval/rerank_output.jsonl
    #     → load pre-computed scores instead of running the local reranker,
    #     then compute metrics as if RERANK=1 had been used inline.
    rerank_input_out = ENV["RERANK_INPUT_OUT"]
    rerank_scores_in = ENV["RERANK_SCORES_IN"]

    # RRF (Reciprocal Rank Fusion) hybrid retrieval.
    # When RRF=1, also run the production FTS strategy (Search::Strategies::TextSearch)
    # for each query and fuse its top-N with the bi-encoder top-N via RRF
    # score = sum(1 / (k + rank_in_list)). The eval reports bi-encoder, FTS,
    # and RRF metrics side-by-side so the lift from fusion is visible.
    rrf = ENV["RRF"] == "1"
    rrf_k = (ENV["RRF_K"] || "60").to_i
    rrf_top_n_per_list = (ENV["RRF_TOP_N"] || "100").to_i
    if rerank_scores_in
      rerank = true # implicit
    end
    if rerank_input_out
      # Dump-only mode: we still go through bi-encoder retrieval but emit the
      # candidate list at the end and skip metric computation. RERANK doesn't
      # need to be set; we'll force ourselves out before the rerank stage.
      rerank = false
    end

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
    # ef_search needs to be ≥ retrieve_n to fill the LIMIT, but going much
    # higher just costs latency. Floor at 100 to ensure recall for tiny K,
    # otherwise scale linearly with retrieve_n.
    raw.exec("SET hnsw.ef_search = #{[retrieve_n * 2, 100].max}")

    # Build the retrieval SQL once. Two cases:
    #  1) emb_table == 'work_units': vector lives on work_units directly,
    #     no join, partial index on (body_embedding IS NOT NULL).
    #  2) emb_table == 'work_unit_embeddings_<slug>': side table; JOIN to
    #     work_units on work_unit_id to fetch canonical_ref_id.
    if emb_table == "work_units"
      retrieval_sql = <<~SQL
        SELECT canonical_ref_id, body
        FROM work_units
        WHERE #{emb_column} IS NOT NULL
          AND canonical_ref_id IS NOT NULL
        ORDER BY #{emb_column} <=> $1::vector
        LIMIT $2
      SQL
    else
      retrieval_sql = <<~SQL
        SELECT wu.canonical_ref_id, wu.body
        FROM #{emb_table} e
        JOIN work_units wu ON wu.id = e.work_unit_id
        WHERE wu.canonical_ref_id IS NOT NULL
        ORDER BY e.#{emb_column} <=> $1::vector
        LIMIT $2
      SQL
    end

    if rerank && rerank_scores_in.nil?
      require Rails.root.join("app/services/search/reranker").to_s
      unless Search::Reranker.instance.model_available?
        abort "RERANK=1 but reranker model not found at #{Search::Reranker::MODEL_DIR}"
      end
      puts "  rerank: top-#{rerank_top_k} via Search::Reranker"
      puts "  rerank instruct: #{rerank_instruct || '(default)'}"
    end

    # Pre-load CUDA-computed scores (Pass 3 of two-pass mode).
    # File format: one JSON object per line: {"qid": "...", "scores": {"<rid>": <float>, ...}}
    cuda_scores = nil
    if rerank_scores_in
      puts "  rerank: loading pre-computed scores from #{rerank_scores_in}"
      cuda_scores = {}
      File.foreach(rerank_scores_in) do |ln|
        ln.strip!
        next if ln.empty?
        obj = JSON.parse(ln)
        cuda_scores[obj["qid"]] = obj["scores"]
      end
      puts "  loaded scores for #{cuda_scores.size} queries"
    end

    # Pass-1 dump file (Pass 1 of two-pass mode).
    rerank_dump_io = nil
    if rerank_input_out
      FileUtils.mkdir_p(File.dirname(rerank_input_out))
      rerank_dump_io = File.open(rerank_input_out, "w")
      puts "  rerank: dumping top-#{rerank_top_k} candidates per query → #{rerank_input_out}"
    end

    if rrf
      require Rails.root.join("app/services/search/strategies/text_search").to_s
      require Rails.root.join("app/services/search/result_set").to_s
      puts "  rrf: hybrid retrieval (bi-encoder + FTS), top-#{rrf_top_n_per_list} per list, k=#{rrf_k}"
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
      ranked = [] # array of {rid:, body:}
      result.each do |row|
        rid = row["canonical_ref_id"].to_i
        next if seen[rid]
        seen[rid] = true
        ranked << { rid: rid, body: row["body"] }
      end

      ranked = ranked.first(100)
      bi_refs = ranked.map { |r| r[:rid] }
      relevant = concept[:relevant]

      score_at_k = ->(refs) {
        hits_at_k = 0
        first_hit_rank = nil
        dcg = 0.0
        refs.first(k).each_with_index do |rid, idx|
          if (role = relevant[rid])
            hits_at_k += 1
            first_hit_rank ||= idx + 1
            gain = ROLE_WEIGHTS[role] || 0.5
            dcg += gain / Math.log2(idx + 2.0)
          end
        end
        ideal_gains = relevant.values.map { |r| ROLE_WEIGHTS[r] || 0.5 }.sort.reverse.first(k)
        idcg = ideal_gains.each_with_index.sum { |g, i| g / Math.log2(i + 2.0) }
        {
          hits_at_k: hits_at_k,
          first_hit_rank: first_hit_rank,
          recall_at_k: relevant.empty? ? 0.0 : (hits_at_k.to_f / relevant.size),
          rr: first_hit_rank ? (1.0 / first_hit_rank) : 0.0,
          ndcg_at_k: idcg.zero? ? 0.0 : (dcg / idcg),
        }
      }

      bi_metrics = score_at_k.call(bi_refs)

      # FTS + RRF (optional). Calls the production text-search strategy and
      # fuses with the bi-encoder list using reciprocal rank fusion.
      fts_metrics = nil
      rrf_metrics = nil
      fts_refs = nil
      rrf_refs = nil
      if rrf
        ts = Search::Strategies::TextSearch.new(q[:text], per_page: rrf_top_n_per_list).call
        fts_refs = ts.results.map { |r| r[:canonical_ref_id] }.compact.uniq
        fts_metrics = score_at_k.call(fts_refs)

        # RRF score = sum(1 / (k + rank_in_list)) over both lists.
        # Items present in both rise to the top — that's the whole point.
        rrf_scores = Hash.new(0.0)
        bi_refs.first(rrf_top_n_per_list).each_with_index { |rid, i| rrf_scores[rid] += 1.0 / (rrf_k + i + 1) }
        fts_refs.first(rrf_top_n_per_list).each_with_index { |rid, i| rrf_scores[rid] += 1.0 / (rrf_k + i + 1) }
        rrf_refs = rrf_scores.sort_by { |_, s| -s }.map(&:first)
        rrf_metrics = score_at_k.call(rrf_refs)
      end

      # Pass-1 dump: write candidates and skip rerank/metrics for this query.
      if rerank_dump_io
        head = ranked.first(rerank_top_k)
        rerank_dump_io.puts({
          qid: qid,
          query: q[:text],
          candidates: head.map { |r| { rid: r[:rid], body: r[:body].to_s } },
        }.to_json)
        n_done += 1
        if n_done % 100 == 0
          $stdout.print "\r  dumped #{n_done}/#{queries.size}"
          $stdout.flush
        end
        next
      end

      rr_metrics = nil
      rr_refs = nil
      if rerank
        head = ranked.first(rerank_top_k)
        tail = ranked.drop(rerank_top_k)
        scores = nil
        if cuda_scores
          # Pass-3 mode: look up scores in the loaded JSONL by rid.
          q_scores = cuda_scores[qid] || {}
          scores = head.map { |r| q_scores[r[:rid].to_s] }
        else
          bodies = head.map { |r| r[:body].to_s }
          kwargs = rerank_instruct ? { instruct: rerank_instruct } : {}
          scores = Search::Reranker.instance.score(q[:text], bodies, **kwargs)
        end
        # If reranker errored (returns nils), fall back to bi-encoder order.
        if scores.compact.size == scores.size
          reranked_head = head.zip(scores).sort_by { |_, s| -s }.map(&:first)
        else
          reranked_head = head
        end
        rr_ranked = reranked_head + tail
        rr_refs = rr_ranked.map { |r| r[:rid] }
        rr_metrics = score_at_k.call(rr_refs)
      end

      per_query_results << {
        qid: qid,
        concept_id: q[:concept_id],
        concept_name: concept[:name],
        kind: concept[:kind],
        variant: q[:variant],
        text: q[:text],
        n_relevant: relevant.size,
        # Bi-encoder metrics (what the existing eval reported)
        hits_at_k: bi_metrics[:hits_at_k],
        first_hit_rank: bi_metrics[:first_hit_rank],
        recall_at_k: bi_metrics[:recall_at_k],
        rr: bi_metrics[:rr],
        ndcg_at_k: bi_metrics[:ndcg_at_k],
        top_k_refs: bi_refs.first(k),
        # Post-rerank metrics (only present if RERANK=1)
        rr_hits_at_k: rr_metrics&.dig(:hits_at_k),
        rr_first_hit_rank: rr_metrics&.dig(:first_hit_rank),
        rr_recall_at_k: rr_metrics&.dig(:recall_at_k),
        rr_rr: rr_metrics&.dig(:rr),
        rr_ndcg_at_k: rr_metrics&.dig(:ndcg_at_k),
        rr_top_k_refs: rr_refs&.first(k),
        # FTS-only metrics (only present if RRF=1)
        fts_hits_at_k: fts_metrics&.dig(:hits_at_k),
        fts_first_hit_rank: fts_metrics&.dig(:first_hit_rank),
        fts_recall_at_k: fts_metrics&.dig(:recall_at_k),
        fts_rr: fts_metrics&.dig(:rr),
        fts_ndcg_at_k: fts_metrics&.dig(:ndcg_at_k),
        # RRF (bi+FTS fusion) metrics (only present if RRF=1)
        rrf_hits_at_k: rrf_metrics&.dig(:hits_at_k),
        rrf_first_hit_rank: rrf_metrics&.dig(:first_hit_rank),
        rrf_recall_at_k: rrf_metrics&.dig(:recall_at_k),
        rrf_rr: rrf_metrics&.dig(:rr),
        rrf_ndcg_at_k: rrf_metrics&.dig(:ndcg_at_k),
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

    if rerank_dump_io
      rerank_dump_io.close
      puts "Dumped #{n_done} queries × top-#{rerank_top_k} candidates → #{rerank_input_out}"
      puts "Next: scp the file + the reranker model to the GPU box, run scripts/eval/rerank_audit_cuda.py, scp scores back, then re-run with RERANK_SCORES_IN=<scored.jsonl>"
      exit 0
    end

    # Per-concept aggregation: best-of-variants (closest to "user phrasing wins")
    by_concept = per_query_results.group_by { |r| r[:concept_id] }
    concept_metrics = by_concept.map do |cid, results|
      best = results.max_by { |r| r[:rr] }
      name_q = results.find { |r| r[:variant] == "name" }
      m = {
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
      if rerank
        rr_best = results.max_by { |r| r[:rr_rr] || 0.0 }
        m[:rr_best_rr]     = rr_best[:rr_rr] || 0.0
        m[:rr_best_recall] = rr_best[:rr_recall_at_k] || 0.0
        m[:rr_best_ndcg]   = rr_best[:rr_ndcg_at_k] || 0.0
        m[:rr_name_rr]     = name_q ? (name_q[:rr_rr] || 0.0) : 0.0
        m[:rr_name_recall] = name_q ? (name_q[:rr_recall_at_k] || 0.0) : 0.0
        m[:rr_name_ndcg]   = name_q ? (name_q[:rr_ndcg_at_k] || 0.0) : 0.0
      end
      if rrf
        # FTS-only
        fts_best = results.max_by { |r| r[:fts_rr] || 0.0 }
        m[:fts_best_rr]     = fts_best[:fts_rr] || 0.0
        m[:fts_best_recall] = fts_best[:fts_recall_at_k] || 0.0
        m[:fts_best_ndcg]   = fts_best[:fts_ndcg_at_k] || 0.0
        m[:fts_name_rr]     = name_q ? (name_q[:fts_rr] || 0.0) : 0.0
        m[:fts_name_recall] = name_q ? (name_q[:fts_recall_at_k] || 0.0) : 0.0
        m[:fts_name_ndcg]   = name_q ? (name_q[:fts_ndcg_at_k] || 0.0) : 0.0
        # RRF (bi+FTS fusion)
        rrf_best = results.max_by { |r| r[:rrf_rr] || 0.0 }
        m[:rrf_best_rr]     = rrf_best[:rrf_rr] || 0.0
        m[:rrf_best_recall] = rrf_best[:rrf_recall_at_k] || 0.0
        m[:rrf_best_ndcg]   = rrf_best[:rrf_ndcg_at_k] || 0.0
        m[:rrf_name_rr]     = name_q ? (name_q[:rrf_rr] || 0.0) : 0.0
        m[:rrf_name_recall] = name_q ? (name_q[:rrf_recall_at_k] || 0.0) : 0.0
        m[:rrf_name_ndcg]   = name_q ? (name_q[:rrf_ndcg_at_k] || 0.0) : 0.0
      end
      m
    end

    by_kind = concept_metrics.group_by { |c| c[:kind] }

    puts
    puts "=" * 78
    puts "THEMATIC RETRIEVAL EVAL @ K=#{k}"
    puts "  Model:      #{model_path}"
    puts "  Concepts:   #{concept_metrics.size}"
    puts "  Variants:   #{queries.size}"
    puts "  Retrieved:  top-#{retrieve_n} work_units, dedupe → top-100 canonical_refs"
    puts "  Rerank:     #{rerank ? "top-#{rerank_top_k} via Search::Reranker" : 'off'}"
    puts "=" * 78
    puts

    fmt = "%-20s %6s %8s %8s %8s %8s %8s %8s"
    puts fmt % %w[kind n MRR(name) MRR(best) R@10(name) R@10(best) NDCG(name) NDCG(best)]
    puts "-" * 78

    # Print one metric row. `prefix` is "" (bi-encoder), "rr_" (rerank),
    # "fts_" (FTS only), or "rrf_" (RRF fusion). Handles missing keys
    # (when a sub-metric wasn't computed) by using 0.0 fallback.
    print_row = ->(label, group, prefix: "") {
      n = group.size
      mrr_name  = group.sum { |c| (c[:"#{prefix}name_rr"]     || 0.0) } / n
      mrr_best  = group.sum { |c| (c[:"#{prefix}best_rr"]     || 0.0) } / n
      rec_name  = group.sum { |c| (c[:"#{prefix}name_recall"] || 0.0) } / n
      rec_best  = group.sum { |c| (c[:"#{prefix}best_recall"] || 0.0) } / n
      ndcg_name = group.sum { |c| (c[:"#{prefix}name_ndcg"]   || 0.0) } / n
      ndcg_best = group.sum { |c| (c[:"#{prefix}best_ndcg"]   || 0.0) } / n
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

    if rerank
      puts "=" * 78
      puts "POST-RERANK (top-#{rerank_top_k} reranked, then top-100)"
      puts "=" * 78
      puts fmt % %w[kind n MRR(name) MRR(best) R@10(name) R@10(best) NDCG(name) NDCG(best)]
      puts "-" * 78
      by_kind.sort_by { |kind, _| kind.to_s }.each do |kind, group|
        print_row.call(kind, group, prefix: "rr_")
      end
      puts "-" * 78
      print_row.call("ALL", concept_metrics, prefix: "rr_")
      puts

      # Lift summary
      n_all = concept_metrics.size
      bi_mrr = concept_metrics.sum { |c| c[:best_rr] } / n_all
      rr_mrr = concept_metrics.sum { |c| c[:rr_best_rr] } / n_all
      bi_ndcg = concept_metrics.sum { |c| c[:best_ndcg] } / n_all
      rr_ndcg = concept_metrics.sum { |c| c[:rr_best_ndcg] } / n_all
      pp_mrr  = (rr_mrr - bi_mrr) * 100
      pp_ndcg = (rr_ndcg - bi_ndcg) * 100
      puts "LIFT (best-of-variants):  MRR  %+.2f pp   NDCG %+.2f pp" % [pp_mrr, pp_ndcg]
      puts
    end

    if rrf
      [["FTS-ONLY (production text-search strategy)", "fts_"],
       ["RRF FUSION (bi-encoder ⊕ FTS, k=#{rrf_k}, top-#{rrf_top_n_per_list} per list)", "rrf_"]].each do |title, prefix|
        puts "=" * 78
        puts title
        puts "=" * 78
        puts fmt % %w[kind n MRR(name) MRR(best) R@10(name) R@10(best) NDCG(name) NDCG(best)]
        puts "-" * 78
        by_kind.sort_by { |kind, _| kind.to_s }.each do |kind, group|
          print_row.call(kind, group, prefix: prefix)
        end
        puts "-" * 78
        print_row.call("ALL", concept_metrics, prefix: prefix)
        puts
      end

      # Lift summary
      n_all = concept_metrics.size
      bi_mrr  = concept_metrics.sum { |c| c[:best_rr] } / n_all
      fts_mrr = concept_metrics.sum { |c| c[:fts_best_rr] } / n_all
      rrf_mrr = concept_metrics.sum { |c| c[:rrf_best_rr] } / n_all
      bi_ndcg  = concept_metrics.sum { |c| c[:best_ndcg] } / n_all
      fts_ndcg = concept_metrics.sum { |c| c[:fts_best_ndcg] } / n_all
      rrf_ndcg = concept_metrics.sum { |c| c[:rrf_best_ndcg] } / n_all
      puts "LIFT (best-of-variants):"
      puts "  bi-encoder → FTS    MRR  %+.2f pp   NDCG %+.2f pp" % [(fts_mrr - bi_mrr) * 100, (fts_ndcg - bi_ndcg) * 100]
      puts "  bi-encoder → RRF    MRR  %+.2f pp   NDCG %+.2f pp" % [(rrf_mrr - bi_mrr) * 100, (rrf_ndcg - bi_ndcg) * 100]
      puts "  FTS        → RRF    MRR  %+.2f pp   NDCG %+.2f pp" % [(rrf_mrr - fts_mrr) * 100, (rrf_ndcg - fts_ndcg) * 100]
      puts
    end

    # Persist
    File.open(out_path, "w") do |f|
      f.puts({
        meta: {
          model_path: model_path, device: device, k: k,
          retrieve_n: retrieve_n, ts: Time.now.iso8601,
          n_concepts: concept_metrics.size, n_queries: queries.size,
          emb_table: emb_table, emb_column: emb_column,
          query_prompt: query_prompt, query_dim: query_dim,
          rerank: rerank, rerank_top_k: rerank ? rerank_top_k : nil,
          rerank_instruct: rerank ? (rerank_instruct || Search::Reranker::DEFAULT_INSTRUCT) : nil,
        }
      }.to_json)
      per_query_results.each { |r| f.puts(r.to_json) }
    end
    puts "Per-query results: #{out_path}"
  end

end
