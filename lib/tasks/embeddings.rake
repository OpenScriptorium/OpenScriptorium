namespace :embeddings do
  desc "Encode all work_units using the trained embedding model"
  task encode_corpus: :environment do
    model_path = ENV.fetch("MODEL_PATH", Rails.root.join("tmp/embedding_model").to_s)
    batch_size = ENV.fetch("BATCH_SIZE", "256").to_i

    abort "Model not found at #{model_path}" unless File.exist?(model_path)

    puts "Loading model from #{model_path}..."

    # Use Python to batch-encode, writing vectors back via a pipe
    require "open3"
    require "json"

    script = <<~PYTHON
      import sys, json
      from sentence_transformers import SentenceTransformer
      import numpy as np

      model = SentenceTransformer(sys.argv[1])
      batch_size = int(sys.argv[2])
      sys.stderr.write("ready\\n")
      sys.stderr.flush()

      batch_ids = []
      batch_texts = []

      for line in sys.stdin:
          line = line.strip()
          if not line:
              continue
          parts = line.split("\\t", 1)
          if len(parts) != 2:
              continue
          batch_ids.append(parts[0])
          batch_texts.append(parts[1])

          if len(batch_ids) >= batch_size:
              vecs = model.encode(batch_texts).tolist()
              for uid, vec in zip(batch_ids, vecs):
                  print(f"{uid}\\t{json.dumps(vec)}", flush=True)
              batch_ids = []
              batch_texts = []

      # Flush remaining
      if batch_ids:
          vecs = model.encode(batch_texts).tolist()
          for uid, vec in zip(batch_ids, vecs):
              print(f"{uid}\\t{json.dumps(vec)}", flush=True)

      sys.stderr.write("done\\n")
      sys.stderr.flush()
    PYTHON

    stdin, stdout, stderr, wait_thread = Open3.popen3(
      "python3", "-c", script, model_path, batch_size.to_s
    )

    # Wait for model to load
    loop do
      line = stderr.gets
      break if line&.include?("ready")
      abort "Model failed to load: #{line}" if line.nil?
    end
    puts "Model loaded. Encoding corpus..."

    conn = ActiveRecord::Base.connection
    total = conn.select_value("SELECT COUNT(*) FROM work_units WHERE body IS NOT NULL AND body != '' AND body != '⸂ ⸃'").to_i
    encoded = 0
    db_batch = []
    db_batch_size = 500

    flush_embeddings = ->(c, b) {
      values = b.map { |id, vec| "(#{id}, '#{vec}'::vector)" }.join(", ")
      c.execute(<<~SQL)
        UPDATE work_units AS wu
        SET body_embedding = v.embedding
        FROM (VALUES #{values}) AS v(id, embedding)
        WHERE wu.id = v.id
      SQL
    }

    # Stream work_units to the Python process
    writer = Thread.new do
      conn.select_all(
        "SELECT id, body FROM work_units WHERE body IS NOT NULL AND body != '' AND body != '⸂ ⸃' ORDER BY id"
      ).each do |row|
        text = row["body"].to_s.gsub(/[\n\r\t]/, " ").strip
        next if text.empty?
        stdin.puts "#{row['id']}\t#{text}"
      end
      stdin.close
    end

    # Read vectors back and batch-update the database
    while (line = stdout.gets)
      parts = line.strip.split("\t", 2)
      next unless parts.size == 2

      db_batch << [parts[0].to_i, parts[1]]

      if db_batch.size >= db_batch_size
        flush_embeddings.(conn, db_batch)
        encoded += db_batch.size
        db_batch = []
        $stdout.print "\r  Encoded #{encoded}/#{total} (#{(encoded * 100.0 / total).round(1)}%)"
        $stdout.flush
      end
    end

    # Flush remaining
    if db_batch.any?
      flush_embeddings.(conn, db_batch)
      encoded += db_batch.size
    end

    writer.join
    wait_thread.join
    puts "\n  Done: #{encoded} encoded, #{total - encoded} skipped"
  end

  desc "Compare embedding models on test pairs"
  task compare_models: :environment do
    models = ENV.fetch("MODELS", "").split(",").map(&:strip)
    abort "Usage: rake embeddings:compare_models MODELS=path1,path2,path3" if models.empty?

    require "json"
    require "open3"

    test_pairs = [
      # Same verse, different translation (should be ~0.95+)
      ["In the beginning God created the heavens and the earth",
       "In the beginning God created the heaven and the earth", "en-en paraphrase"],
      # Hebrew ↔ English (should be high after training)
      ["בְּרֵאשִׁית בָּרָא אֱלֹהִים אֵת הַשָּׁמַיִם וְאֵת הָאָרֶץ",
       "In the beginning God created the heavens and the earth", "he-en Gen 1:1"],
      # Greek ↔ English
      ["Ἐν ἀρχῇ ἦν ὁ λόγος καὶ ὁ λόγος ἦν πρὸς τὸν θεόν",
       "In the beginning was the Word and the Word was with God", "gr-en John 1:1"],
      # Single word cross-language
      ["ἀγάπη", "love", "gr-en word"],
      ["שָׁלוֹם", "peace", "he-en word"],
      ["שָׁלוֹם", "εἰρήνη", "he-gr word"],
      # Related passages (should be moderate ~0.5-0.8)
      ["For God so loved the world that He gave His only begotten Son",
       "God is love", "thematic"],
      # Unrelated (should be low ~0.1-0.3)
      ["In the beginning God created the heavens and the earth",
       "The Lord is my shepherd I shall not want", "unrelated"],
      ["Blessed are the poor in spirit",
       "You shall not steal", "unrelated"],
    ]

    models.each do |model_path|
      puts "\n#{'=' * 50}"
      puts "Model: #{model_path}"
      puts "#{'=' * 50}"

      script = <<~PYTHON
        import sys, json, os
        os.environ['TQDM_DISABLE'] = '1'
        os.environ['TRANSFORMERS_VERBOSITY'] = 'error'
        from sentence_transformers import SentenceTransformer
        from sentence_transformers.util import cos_sim

        sys.stderr.write("loading...\\n")
        sys.stderr.flush()
        model = SentenceTransformer(sys.argv[1])
        sys.stderr.write("ready\\n")
        sys.stderr.flush()

        pairs = json.loads(sys.stdin.read())
        for t1, t2, label in pairs:
            e1 = model.encode(t1)
            e2 = model.encode(t2)
            sim = cos_sim(e1, e2).item()
            print(f"{sim:.4f}\\t{label}")
      PYTHON

      stdin, stdout, stderr, wait = Open3.popen3("python3", "-c", script, model_path)

      # Send all pairs as a single JSON array, then close stdin
      stdin.puts test_pairs.to_json
      stdin.close

      # Wait for model to load
      while (line = stderr.gets)
        break if line.include?("ready")
        $stdout.puts "  #{line.strip}" if line.include?("loading")
      end

      # Read all results
      while (line = stdout.gets)
        sim, label = line.strip.split("\t", 2)
        pair = test_pairs.find { |_, _, l| l == label }
        if pair
          puts "  #{sim}  #{label.ljust(20)}  #{pair[0][0..35].ljust(38)} ↔ #{pair[1][0..35]}"
        end
      end

      wait.join
    end
  end

  desc "Export training pairs for sentence embedding fine-tuning (JSONL)"
  task export_training_data: :environment do
    require "json"

    output_dir = Rails.root.join("tmp/embedding_training")
    FileUtils.mkdir_p(output_dir)

    conn = ActiveRecord::Base.connection

    # ═══════════════════════════════════════════════════════════════
    # Part A: English paraphrase pairs (same verse, different translation)
    # ═══════════════════════════════════════════════════════════════
    puts "Exporting English paraphrase pairs..."

    english_works = conn.select_all(<<~SQL).to_a
      SELECT id, slug, title FROM works
      WHERE work_type IN ('scripture_translation', 'scripture_original')
        AND language = 'en'
      ORDER BY slug
    SQL

    pair_count = 0
    File.open(output_dir.join("paraphrase_pairs.jsonl"), "w") do |f|
      # Use BSB as the anchor — pair it with every other English translation
      bsb = english_works.find { |w| w["slug"] == "bsb" }
      next puts("  SKIP: BSB not found") unless bsb

      others = english_works.reject { |w| w["slug"] == "bsb" }
      others.each do |other|
        rows = conn.select_all(<<~SQL, "pairs", [bsb["id"], other["id"]])
          SELECT wu1.body AS text1, wu2.body AS text2,
                 cr.sbl_citation AS ref
          FROM work_units wu1
          JOIN work_units wu2 ON wu1.canonical_ref_id = wu2.canonical_ref_id
          JOIN canonical_refs cr ON cr.id = wu1.canonical_ref_id
          WHERE wu1.work_id = $1 AND wu2.work_id = $2
            AND wu1.body IS NOT NULL AND wu1.body != ''
            AND wu2.body IS NOT NULL AND wu2.body != ''
          ORDER BY cr.ord
        SQL

        rows.each do |r|
          f.puts({ type: "paraphrase",
                   text1: r["text1"], text2: r["text2"],
                   ref: r["ref"],
                   work1: "bsb", work2: other["slug"] }.to_json)
          pair_count += 1
        end
        puts "  bsb ↔ #{other['slug']}: #{rows.count} pairs"
      end
    end
    puts "  Total paraphrase pairs: #{pair_count}"
    puts

    # ═══════════════════════════════════════════════════════════════
    # Part B: Hebrew–English word alignment pairs
    # ═══════════════════════════════════════════════════════════════
    puts "Exporting Hebrew–English alignment pairs..."

    he_en_count = 0
    File.open(output_dir.join("hebrew_english_pairs.jsonl"), "w") do |f|
      wlc_id = conn.select_value("SELECT id FROM works WHERE slug = 'wlc'")
      bsb_id = conn.select_value("SELECT id FROM works WHERE slug = 'bsb'")

      if wlc_id && bsb_id
        rows = conn.select_all(<<~SQL, "he_en", [wlc_id, bsb_id])
          SELECT
            STRING_AGG(DISTINCT w_src.surface, ' ' ORDER BY w_src.surface) AS source_text,
            STRING_AGG(DISTINCT w_tgt.surface, ' ' ORDER BY w_tgt.surface) AS target_text,
            l_src.lemma AS source_lemma,
            l_src.primary_gloss AS source_gloss,
            w_src.strongs_number,
            ag.alignment_type,
            cr.sbl_citation AS ref
          FROM alignment_groups ag
          JOIN canonical_refs cr ON cr.id = ag.canonical_ref_id
          JOIN alignment_group_members agm_src
            ON agm_src.alignment_group_id = ag.id AND agm_src.role = 'source'
          JOIN words w_src ON w_src.id = agm_src.word_id
          LEFT JOIN lemmas l_src ON l_src.id = w_src.lemma_id
          JOIN alignment_group_members agm_tgt
            ON agm_tgt.alignment_group_id = ag.id AND agm_tgt.role = 'target'
          JOIN words w_tgt ON w_tgt.id = agm_tgt.word_id
          WHERE ag.source_work_id = $1 AND ag.target_work_id = $2
          GROUP BY ag.id, l_src.lemma, l_src.primary_gloss,
                   w_src.strongs_number, ag.alignment_type, cr.sbl_citation, cr.ord
          ORDER BY cr.ord
        SQL

        rows.each do |r|
          next if r["source_text"].blank? || r["target_text"].blank?
          f.puts({ type: "alignment_he_en",
                   source: r["source_text"], target: r["target_text"],
                   lemma: r["source_lemma"], gloss: r["source_gloss"],
                   strongs: r["strongs_number"],
                   alignment_type: r["alignment_type"],
                   ref: r["ref"] }.to_json)
          he_en_count += 1
        end
      end
    end
    puts "  Hebrew–English pairs: #{he_en_count}"
    puts

    # ═══════════════════════════════════════════════════════════════
    # Part C: Greek–English word alignment pairs
    # ═══════════════════════════════════════════════════════════════
    puts "Exporting Greek–English alignment pairs..."

    gr_en_count = 0
    File.open(output_dir.join("greek_english_pairs.jsonl"), "w") do |f|
      nestle_id = conn.select_value("SELECT id FROM works WHERE slug = 'nestle1904'")
      bsb_id = conn.select_value("SELECT id FROM works WHERE slug = 'bsb'")

      if nestle_id && bsb_id
        rows = conn.select_all(<<~SQL, "gr_en", [nestle_id, bsb_id])
          SELECT
            STRING_AGG(DISTINCT w_src.surface, ' ' ORDER BY w_src.surface) AS source_text,
            STRING_AGG(DISTINCT w_tgt.surface, ' ' ORDER BY w_tgt.surface) AS target_text,
            l_src.lemma AS source_lemma,
            l_src.primary_gloss AS source_gloss,
            w_src.strongs_number,
            ag.alignment_type,
            cr.sbl_citation AS ref
          FROM alignment_groups ag
          JOIN canonical_refs cr ON cr.id = ag.canonical_ref_id
          JOIN alignment_group_members agm_src
            ON agm_src.alignment_group_id = ag.id AND agm_src.role = 'source'
          JOIN words w_src ON w_src.id = agm_src.word_id
          LEFT JOIN lemmas l_src ON l_src.id = w_src.lemma_id
          JOIN alignment_group_members agm_tgt
            ON agm_tgt.alignment_group_id = ag.id AND agm_tgt.role = 'target'
          JOIN words w_tgt ON w_tgt.id = agm_tgt.word_id
          WHERE ag.source_work_id = $1 AND ag.target_work_id = $2
          GROUP BY ag.id, l_src.lemma, l_src.primary_gloss,
                   w_src.strongs_number, ag.alignment_type, cr.sbl_citation, cr.ord
          ORDER BY cr.ord
        SQL

        rows.each do |r|
          next if r["source_text"].blank? || r["target_text"].blank?
          f.puts({ type: "alignment_gr_en",
                   source: r["source_text"], target: r["target_text"],
                   lemma: r["source_lemma"], gloss: r["source_gloss"],
                   strongs: r["strongs_number"],
                   alignment_type: r["alignment_type"],
                   ref: r["ref"] }.to_json)
          gr_en_count += 1
        end
      end
    end
    puts "  Greek–English pairs: #{gr_en_count}"
    puts

    # ═══════════════════════════════════════════════════════════════
    # Part D: Cross-reference semantic pairs
    # ═══════════════════════════════════════════════════════════════
    puts "Exporting cross-reference semantic pairs..."

    xref_count = 0
    File.open(output_dir.join("crossref_pairs.jsonl"), "w") do |f|
      bsb_id = conn.select_value("SELECT id FROM works WHERE slug = 'bsb'")
      next puts("  SKIP: BSB not found") unless bsb_id

      rows = conn.select_all(<<~SQL, "xref", [bsb_id])
        SELECT
          wu_src.body AS text1,
          wu_tgt.body AS text2,
          cr_src.sbl_citation AS ref1,
          cr_tgt.sbl_citation AS ref2,
          xr.relationship_type,
          xr.confidence
        FROM cross_references xr
        JOIN canonical_refs cr_src
          ON cr_src.canonical_work_id = xr.source_canonical_work_id
          AND cr_src.ord = lower(xr.source_range)
        JOIN work_units wu_src
          ON wu_src.canonical_ref_id = cr_src.id AND wu_src.work_id = $1
        JOIN canonical_refs cr_tgt
          ON cr_tgt.canonical_work_id = xr.target_canonical_work_id
          AND cr_tgt.ord = lower(xr.target_range)
        JOIN work_units wu_tgt
          ON wu_tgt.canonical_ref_id = cr_tgt.id AND wu_tgt.work_id = $1
        WHERE xr.status = 'approved'
          AND wu_src.body IS NOT NULL AND wu_src.body != ''
          AND wu_tgt.body IS NOT NULL AND wu_tgt.body != ''
        ORDER BY cr_src.ord
      SQL

      rows.each do |r|
        f.puts({ type: "crossref",
                 text1: r["text1"], text2: r["text2"],
                 ref1: r["ref1"], ref2: r["ref2"],
                 relationship: r["relationship_type"],
                 confidence: r["confidence"]&.to_f }.to_json)
        xref_count += 1
      end
    end
    puts "  Cross-reference pairs: #{xref_count}"
    puts

    # ═══════════════════════════════════════════════════════════════
    # Part E: Verse-level Hebrew/Greek–English parallel pairs
    # (full verse text, not word-level)
    # ═══════════════════════════════════════════════════════════════
    puts "Exporting verse-level cross-language pairs..."

    verse_xl_count = 0
    File.open(output_dir.join("verse_crosslang_pairs.jsonl"), "w") do |f|
      [
        ["wlc", "bsb", "he_en"],
        ["nestle1904", "bsb", "gr_en"],
        ["rahlfs-lxx", "brenton-lxx", "gr_en_lxx"],
      ].each do |src_slug, tgt_slug, label|
        src_id = conn.select_value("SELECT id FROM works WHERE slug = #{conn.quote(src_slug)}")
        tgt_id = conn.select_value("SELECT id FROM works WHERE slug = #{conn.quote(tgt_slug)}")
        next unless src_id && tgt_id

        rows = conn.select_all(<<~SQL, label, [src_id, tgt_id])
          SELECT wu_src.body AS source_text, wu_tgt.body AS target_text,
                 cr.sbl_citation AS ref
          FROM work_units wu_src
          JOIN work_units wu_tgt ON wu_src.canonical_ref_id = wu_tgt.canonical_ref_id
          JOIN canonical_refs cr ON cr.id = wu_src.canonical_ref_id
          WHERE wu_src.work_id = $1 AND wu_tgt.work_id = $2
            AND wu_src.body IS NOT NULL AND wu_src.body != ''
            AND wu_tgt.body IS NOT NULL AND wu_tgt.body != ''
          ORDER BY cr.ord
        SQL

        rows.each do |r|
          f.puts({ type: "verse_crosslang",
                   source: r["source_text"], target: r["target_text"],
                   source_work: src_slug, target_work: tgt_slug,
                   ref: r["ref"] }.to_json)
          verse_xl_count += 1
        end
        puts "  #{src_slug} ↔ #{tgt_slug}: #{rows.count} pairs"
      end
    end
    puts "  Total verse cross-language pairs: #{verse_xl_count}"
    puts

    # ═══════════════════════════════════════════════════════════════
    # Summary
    # ═══════════════════════════════════════════════════════════════
    total = pair_count + he_en_count + gr_en_count + xref_count + verse_xl_count
    puts "=" * 50
    puts "EXPORT COMPLETE"
    puts "  Paraphrase pairs:       #{pair_count}"
    puts "  Hebrew–English words:   #{he_en_count}"
    puts "  Greek–English words:    #{gr_en_count}"
    puts "  Cross-reference pairs:  #{xref_count}"
    puts "  Verse cross-language:   #{verse_xl_count}"
    puts "  TOTAL:                  #{total}"
    puts "  Output: #{output_dir}"
    puts

    # File sizes
    Dir.glob(output_dir.join("*.jsonl")).sort.each do |path|
      size = File.size(path)
      puts "  #{File.basename(path).ljust(35)} #{(size / 1024.0 / 1024.0).round(1)} MB"
    end
  end

  desc "Export corpus training pairs (scripture + commentary + lexicon) for the 'everything' model"
  task export_corpus_training_data: :environment do
    require "json"

    output_dir = Rails.root.join("tmp/embedding_training_corpus")
    FileUtils.mkdir_p(output_dir)

    conn = ActiveRecord::Base.connection
    counts = Hash.new(0)

    # ═══════════════════════════════════════════════════════════════
    # Part A: Everything from the scripture export
    # ═══════════════════════════════════════════════════════════════
    puts "Including all scripture training data..."
    scripture_dir = Rails.root.join("tmp/embedding_training")
    %w[paraphrase_pairs.jsonl hebrew_english_pairs.jsonl greek_english_pairs.jsonl
       crossref_pairs.jsonl verse_crosslang_pairs.jsonl].each do |fname|
      src = scripture_dir.join(fname)
      dst = output_dir.join(fname)
      if src.exist?
        FileUtils.cp(src, dst)
        c = File.foreach(dst).count
        counts[fname] = c
        puts "  Copied #{fname}: #{c} pairs"
      else
        puts "  SKIP: #{fname} not found — run embeddings:export_training_data first"
      end
    end

    # ═══════════════════════════════════════════════════════════════
    # Part B: Commentary ↔ source text pairs
    # Pairs each commentary work_unit with the BSB verse at the same
    # canonical_ref. Teaches: "this Rashi comment is about this verse."
    # ═══════════════════════════════════════════════════════════════
    puts "\nExporting commentary ↔ source text pairs..."

    commentary_count = 0
    File.open(output_dir.join("commentary_source_pairs.jsonl"), "w") do |f|
      bsb_id = conn.select_value("SELECT id FROM works WHERE slug = 'bsb'")
      next puts("  SKIP: BSB not found") unless bsb_id

      # English commentary (Soncino) ↔ BSB
      soncino_id = conn.select_value("SELECT id FROM works WHERE slug = 'soncino-bavli'")
      if soncino_id
        rows = conn.select_all(<<~SQL, "soncino_bsb", [soncino_id, bsb_id])
          SELECT commentary.body AS text1, scripture.body AS text2,
                 cr.sbl_citation AS ref
          FROM work_units commentary
          JOIN work_units scripture ON scripture.canonical_ref_id = commentary.canonical_ref_id
          JOIN canonical_refs cr ON cr.id = commentary.canonical_ref_id
          WHERE commentary.work_id = $1 AND scripture.work_id = $2
            AND commentary.body IS NOT NULL AND commentary.body != ''
            AND scripture.body IS NOT NULL AND scripture.body != ''
          ORDER BY cr.ord
        SQL

        rows.each do |r|
          f.puts({ type: "commentary_source",
                   text1: r["text1"], text2: r["text2"],
                   ref: r["ref"],
                   commentary_work: "soncino-bavli", source_work: "bsb" }.to_json)
          commentary_count += 1
        end
        puts "  soncino-bavli ↔ bsb: #{rows.count} pairs"
      end

      # Aramaic commentary (Rashi, Tosafot) ↔ Bavli Gemara
      bavli_id = conn.select_value("SELECT id FROM works WHERE slug = 'bavli'")
      if bavli_id
        %w[rashi-bavli tosafot-bavli].each do |commentary_slug|
          comm_id = conn.select_value("SELECT id FROM works WHERE slug = #{conn.quote(commentary_slug)}")
          next unless comm_id

          rows = conn.select_all(<<~SQL, commentary_slug, [comm_id, bavli_id])
            SELECT commentary.body AS text1, gemara.body AS text2,
                   cr.sbl_citation AS ref
            FROM work_units commentary
            JOIN work_units gemara ON gemara.canonical_ref_id = commentary.canonical_ref_id
            JOIN canonical_refs cr ON cr.id = commentary.canonical_ref_id
            WHERE commentary.work_id = $1 AND gemara.work_id = $2
              AND commentary.body IS NOT NULL AND commentary.body != ''
              AND gemara.body IS NOT NULL AND gemara.body != ''
            ORDER BY cr.ord
            LIMIT 100000
          SQL

          rows.each do |r|
            f.puts({ type: "commentary_source",
                     text1: r["text1"], text2: r["text2"],
                     ref: r["ref"],
                     commentary_work: commentary_slug, source_work: "bavli" }.to_json)
            commentary_count += 1
          end
          puts "  #{commentary_slug} ↔ bavli: #{rows.count} pairs"
        end
      end
    end
    counts["commentary_source_pairs.jsonl"] = commentary_count
    puts "  Total commentary pairs: #{commentary_count}"

    # ═══════════════════════════════════════════════════════════════
    # Part C: Lexicon gloss ↔ example verse pairs
    # Pairs lemma glosses with verses where that lemma appears.
    # Teaches: "this dictionary definition relates to this verse."
    # ═══════════════════════════════════════════════════════════════
    puts "\nExporting lexicon gloss ↔ verse pairs..."

    lexicon_count = 0
    File.open(output_dir.join("lexicon_verse_pairs.jsonl"), "w") do |f|
      bsb_id = conn.select_value("SELECT id FROM works WHERE slug = 'bsb'")
      next puts("  SKIP: BSB not found") unless bsb_id

      # For each glossed lemma, pick up to 3 example verses from BSB
      rows = conn.select_all(<<~SQL, "lexicon", [bsb_id])
        SELECT l.lemma, l.primary_gloss, l.transliteration, l.language,
               wu.body AS verse_text, cr.sbl_citation AS ref
        FROM lemmas l
        JOIN words w ON w.lemma_id = l.id
        JOIN work_units wu ON wu.id = w.work_unit_id
        JOIN canonical_refs cr ON cr.id = wu.canonical_ref_id
        WHERE wu.work_id = $1
          AND l.primary_gloss IS NOT NULL AND l.primary_gloss != ''
          AND wu.body IS NOT NULL AND wu.body != ''
          AND l.frequency > 5
          AND l.frequency < 500
        ORDER BY l.id, RANDOM()
      SQL

      # Deduplicate: max 3 verses per lemma
      seen = Hash.new(0)
      rows.each do |r|
        lemma_id_key = "#{r['lemma']}|#{r['language']}"
        next if seen[lemma_id_key] >= 3
        seen[lemma_id_key] += 1

        gloss_text = "#{r['lemma']} (#{r['transliteration']}): #{r['primary_gloss']}"
        f.puts({ type: "lexicon_verse",
                 text1: gloss_text, text2: r["verse_text"],
                 ref: r["ref"],
                 lemma: r["lemma"], language: r["language"] }.to_json)
        lexicon_count += 1
      end
    end
    counts["lexicon_verse_pairs.jsonl"] = lexicon_count
    puts "  Lexicon ↔ verse pairs: #{lexicon_count}"

    # ═══════════════════════════════════════════════════════════════
    # Part D: French/German/Latin ↔ English verse pairs
    # ═══════════════════════════════════════════════════════════════
    puts "\nExporting additional cross-language pairs..."

    extra_xl_count = 0
    File.open(output_dir.join("extra_crosslang_pairs.jsonl"), "w") do |f|
      [
        ["luther-1912", "bsb", "de_en"],
        ["segond-1910", "bsb", "fr_en"],
        ["crampon-1904", "bsb", "fr_en_catholic"],
        ["vulgate-clementine", "bsb", "la_en"],
      ].each do |src_slug, tgt_slug, label|
        src_id = conn.select_value("SELECT id FROM works WHERE slug = #{conn.quote(src_slug)}")
        tgt_id = conn.select_value("SELECT id FROM works WHERE slug = #{conn.quote(tgt_slug)}")
        next unless src_id && tgt_id

        rows = conn.select_all(<<~SQL, label, [src_id, tgt_id])
          SELECT wu_src.body AS source_text, wu_tgt.body AS target_text,
                 cr.sbl_citation AS ref
          FROM work_units wu_src
          JOIN work_units wu_tgt ON wu_src.canonical_ref_id = wu_tgt.canonical_ref_id
          JOIN canonical_refs cr ON cr.id = wu_src.canonical_ref_id
          WHERE wu_src.work_id = $1 AND wu_tgt.work_id = $2
            AND wu_src.body IS NOT NULL AND wu_src.body != ''
            AND wu_tgt.body IS NOT NULL AND wu_tgt.body != ''
          ORDER BY cr.ord
        SQL

        rows.each do |r|
          f.puts({ type: "verse_crosslang",
                   source: r["source_text"], target: r["target_text"],
                   source_work: src_slug, target_work: tgt_slug,
                   ref: r["ref"] }.to_json)
          extra_xl_count += 1
        end
        puts "  #{src_slug} ↔ #{tgt_slug}: #{rows.count} pairs"
      end
    end
    counts["extra_crosslang_pairs.jsonl"] = extra_xl_count
    puts "  Extra cross-language pairs: #{extra_xl_count}"

    # ═══════════════════════════════════════════════════════════════
    # Summary
    # ═══════════════════════════════════════════════════════════════
    total = counts.values.sum
    puts
    puts "=" * 50
    puts "CORPUS EXPORT COMPLETE"
    counts.each { |k, v| puts "  #{k.ljust(40)} #{v}" }
    puts "  #{'TOTAL'.ljust(40)} #{total}"
    puts "  Output: #{output_dir}"
    puts

    Dir.glob(output_dir.join("*.jsonl")).sort.each do |path|
      size = File.size(path)
      puts "  #{File.basename(path).ljust(40)} #{(size / 1024.0 / 1024.0).round(1)} MB"
    end
  end
end
