namespace :import do
  desc "Import the Berean Standard Bible from bereanbible.com"
  task bsb: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::BsbImporter.new(download: download).call
  end

  desc "Import the Berean interlinear tables (WLC Hebrew + Nestle 1904 Greek)"
  task bsb_tables: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::BsbTablesImporter.new(download: download).call
  end

  desc "Import the Robinson-Pierpont Byzantine Greek New Testament"
  task rp: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::RobinsonPierpontImporter.new(download: download).call
  end

  desc "Import the Rahlfs Septuagint (1935) Greek text"
  task rahlfs: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::RahlfsImporter.new(download: download).call
  end

  desc "Import Brenton's English translation of the Septuagint (1851)"
  task brenton: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::BrentonImporter.new(download: download).call
  end

  desc "Import STEPBible TVTMS verse mapping data (LXX/MT/Vulgate ↔ KJV)"
  task tvtms: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::TvtmsImporter.new(download: download).call
  end

  desc "Import the King James Version (1769) with Apocrypha + 1611 marginal notes"
  task kjva: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::KjvaImporter.new(download: download).call
  end

  desc "Import the JPS 1917 English Tanakh + footnotes from JPS Press's PDF"
  task jps1917: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::Jps1917Importer.new(download: download).call
  end

  desc "Import the Lutherbibel 1912 (German) from the Karl-Barth TEI"
  task luther1912: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::Luther1912Importer.new(download: download).call
  end

  desc "Add Strong's numbers and lemmas to the KJV from kaiserlik/kjv"
  task kjv_strongs: :environment do
    Importers::KjvStrongsImporter.new.call
  end

  desc "Import the Louis Segond 1910 French Bible from USFM"
  task segond: :environment do
    Importers::SegondImporter.new.call
  end

  desc "Add morphology and lemmas to Rahlfs LXX from CATSS parsed Septuagint"
  task rahlfs_morph: :environment do
    Importers::RahlfsMorphImporter.new.call
  end

  desc "Import the CNTR Statistical Restoration Greek NT (CC BY 4.0)"
  task cntr_sr: :environment do
    Importers::CntrSrImporter.new.call
  end

  desc "Import OpenBible.info cross-references (CC BY 4.0, ~344k links)"
  task openbible_xrefs: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::OpenbibleXrefsImporter.new(download: download).call
  end

  desc "Import Treasury of Scripture Knowledge cross-references (CC BY-SA 4.0, ~305k links)"
  task tsk: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::TskImporter.new(download: download).call
  end

  desc "Import critical apparatus from CNTR manuscript transcriptions (CC BY-SA 4.0)"
  task cntr_apparatus: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::CntrApparatusImporter.new(download: download).call
  end

  desc "Import Nestle 1904 apparatus from WHNU-guided DjVu extraction (PD)"
  task nestle_apparatus: :environment do
    Importers::NestleApparatusImporter.new.call
  end

  desc "Import the Crampon 1904 French Catholic Bible (PD, 73 books with deuterocanon)"
  task crampon: :environment do
    Importers::CramponImporter.new.call
  end

  desc "Import the Clementine Vulgate (Latin, PD, 78 books with deuterocanon)"
  task vulgate: :environment do
    Importers::VulgateImporter.new.call
  end

  desc "Import the 1904 Patriarchal Greek NT (Orthodox, PD, with Strong's)"
  task patriarchal_nt: :environment do
    Importers::PatriarchalNtImporter.new.call
  end

  desc "Add Brenton's translator footnotes from the USFM edition"
  task brenton_notes: :environment do
    Importers::BrentonNotesImporter.new.call
  end

  desc "Import WEBBE (World English Bible British Edition with Deuterocanon, PD)"
  task webbe: :environment do
    Importers::WebbeImporter.new.call
  end

  desc "Add Ketiv/Qere notes + parashot to WLC from OSHB MAPM XML"
  task oshb_features: :environment do
    Importers::OshbFeaturesImporter.new.call
  end

  desc "Import Babylonian Talmud (Gemara + Rashi + Tosafot) from Sefaria export"
  task bavli: :environment do
    Importers::BavliImporter.new.call
  end

  desc "Import Sefaria cross-reference links (Talmud↔Tanakh, Talmud↔Talmud)"
  task sefaria_links: :environment do
    Importers::SefariaLinksImporter.new.call
  end

  desc "Import Vilna margin commentaries (Rashash, Maharsha, Gilyon HaShas, etc.)"
  task vilna_margins: :environment do
    Importers::VilnaMarginsImporter.new.call
  end

  desc "Import Soncino English Talmud from halakhah.com"
  task soncino: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::SoncinoImporter.new(download: download).call
  end

  desc "Import Ein Mishpat / Mesoret HaShas margin references from Sefaria links"
  task vilna_refs: :environment do
    Importers::VilnaRefsImporter.new.call
  end

  desc "Import Swete's Septuagint (CC BY-SA 4.0) from nathans/lxx-swete"
  task swete: :environment do
    Importers::SweteImporter.new.call
  end

  desc "Import STEP Bible lexicon data (CC BY 4.0): clean glosses, dedup lemmas, backfill frequencies"
  task step_lexicon: :environment do
    Importers::StepLexiconImporter.new.call
  end

  desc "Fix Hebrew/Greek lemmas to root forms using Macula stronglemma data"
  task macula_lemma_fix: :environment do
    Importers::MaculaLemmaFixImporter.new.call
  end

  desc "Import participant references from Macula (coreference, subject refs, semantic frames)"
  task macula_participants: :environment do
    Importers::MaculaParticipantsImporter.new.call
  end

  desc "Import semantic domain codes from Macula (SDBH, lexdomain, coredomain)"
  task macula_domains: :environment do
    Importers::MaculaDomainsImporter.new.call
  end

  desc "Import Macula syntax trees (CC BY 4.0) for syntactic search"
  task macula_syntax: :environment do
    Importers::MaculaSyntaxImporter.new.call
  end

  desc "Import passage aliases (named passages, parables, events, etc.)"
  task passage_aliases: :environment do
    Importers::PassageAliasesImporter.new.call
  end

  desc "Run all importers in dependency order (see doc/import_dependency_tree.md)"
  task all: :environment do
    require "parallel" if defined?(Parallel) || Gem.loaded_specs["parallel"]

    # Dependency-ordered phases. Importers within a phase are independent
    # of each other but depend on all previous phases completing.
    PHASES = [
      # Phase 0: Foundation — no dependencies
      { name: "Foundation", tasks: %w[bsb kjva rahlfs rp], parallel: true },
      # Phase 1: Depends on Phase 0 works
      { name: "Phase 0 dependents", tasks: %w[bsb_tables brenton kjv_strongs jps1917 luther1912] },
      # Phase 2: Depends on Phase 1 outputs
      # rahlfs_morph REMOVED — CATSS source data is non-free (academic use only)
      { name: "Versification + annotations", tasks: %w[tvtms oshb_features nestle_apparatus brenton_notes] },
      # Phase 3: Independent scripture translations (including Swete LXX)
      { name: "Additional translations", tasks: %w[cntr_sr patriarchal_nt webbe vulgate crampon segond swete] },
      # Phase 4: Cross-references + apparatus
      { name: "Cross-references + apparatus", tasks: %w[cntr_apparatus openbible_xrefs tsk] },
      # Phase 5: Talmud
      { name: "Talmud", tasks: %w[bavli] },
      # Phase 6: Bavli dependents
      { name: "Bavli dependents", tasks: %w[soncino vilna_margins sefaria_links], parallel: true },
      # Phase 7: Vilna refs (needs vilna_margins)
      { name: "Vilna references", tasks: %w[vilna_refs] },
      # Phase 8: Lexicon cleanup (needs all word data)
      { name: "Lexicon cleanup", tasks: %w[step_lexicon] },
    ]

    # Non-essential indexes to drop before import and rebuild after.
    # These slow down inserts significantly (especially GIN/GIST).
    # Primary keys, unique constraints, and foreign keys are kept.
    DROPPABLE_INDEXES = %w[
      idx_work_units_body_tsvector
      idx_work_units_body_embedding_hnsw
      index_words_on_strongs_number
      idx_lemmas_gloss_fts
      idx_lemmas_normalized_trgm
      idx_lemmas_transliteration_trgm
    ].freeze

    # Force stdout to flush every line so progress shows in real time
    $stdout.sync = true

    log_file = Rails.root.join("tmp/import_all_#{Time.now.strftime('%Y%m%d_%H%M%S')}.log")
    results = []
    mutex = Mutex.new

    log = ->(msg) {
      line = "[#{Time.now.strftime('%H:%M:%S')}] #{msg}"
      mutex.synchronize do
        $stdout.puts line
        File.open(log_file, "a") { |f| f.puts line }
      end
    }

    log.("=" * 60)
    log.("import:all — starting full reimport")
    log.("Log file: #{log_file}")
    log.("=" * 60)

    # Postgres tuning for bulk import
    conn = ActiveRecord::Base.connection
    log.("Tuning Postgres for bulk import...")
    conn.execute("SET synchronous_commit = OFF")
    conn.execute("SET work_mem = '256MB'")
    conn.execute("SET maintenance_work_mem = '512MB'")

    # Drop non-essential indexes
    log.("Dropping non-essential indexes...")
    dropped_indexes = []
    DROPPABLE_INDEXES.each do |idx|
      begin
        # Get the index definition so we can recreate it later
        defn = conn.select_value("SELECT pg_get_indexdef(oid) FROM pg_class WHERE relname = '#{idx}'")
        if defn
          conn.execute("DROP INDEX IF EXISTS #{idx}")
          dropped_indexes << { name: idx, definition: defn }
          log.("  Dropped #{idx}")
        end
      rescue => e
        log.("  Skip #{idx}: #{e.message}")
      end
    end

    total_start = Time.now

    PHASES.each_with_index do |phase, phase_idx|
      log.("")
      log.("━━━ Phase #{phase_idx}: #{phase[:name]} (#{phase[:tasks].join(', ')}) ━━━")

      run_task = ->(task_name) {
        log.("  Starting import:#{task_name}...")
        task_start = Time.now

        begin
          # Snapshot row counts before
          counts_before = {}
          %w[works work_units canonical_works canonical_refs words lemmas
             alignment_groups cross_references versification_mappings
             variant_units readings manuscripts pericopes work_unit_notes].each do |table|
            counts_before[table] = ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{table}").to_i
          rescue
            counts_before[table] = 0
          end

          Rake::Task["import:#{task_name}"].invoke

          elapsed = (Time.now - task_start).round(1)

          # Snapshot row counts after
          deltas = []
          counts_before.each do |table, before|
            after = ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{table}").to_i rescue 0
            diff = after - before
            deltas << "#{table}:+#{diff}" if diff > 0
          end

          log.("  ✓ import:#{task_name} completed in #{elapsed}s")
          log.("    Rows added: #{deltas.any? ? deltas.join(', ') : 'none'}") if deltas.any?
          mutex.synchronize { results << { task: task_name, status: :ok, elapsed: elapsed, deltas: deltas } }
        rescue => e
          elapsed = (Time.now - task_start).round(1)
          log.("  ✗ import:#{task_name} FAILED in #{elapsed}s: #{e.class}: #{e.message}")
          log.("    #{e.backtrace.first(3).join("\n    ")}")
          mutex.synchronize { results << { task: task_name, status: :failed, elapsed: elapsed, error: e.message } }
        ensure
          Rake::Task["import:#{task_name}"].reenable
        end
      }

      phase[:tasks].each { |task_name| run_task.(task_name) }
    end

    # Rebuild dropped indexes
    log.("")
    log.("Rebuilding indexes...")
    dropped_indexes.each do |idx|
      begin
        conn.execute(idx[:definition])
        log.("  Rebuilt #{idx[:name]}")
      rescue => e
        log.("  Failed to rebuild #{idx[:name]}: #{e.message}")
      end
    end

    # Reset Postgres settings
    conn.execute("SET synchronous_commit = ON")
    conn.execute("RESET work_mem")
    conn.execute("RESET maintenance_work_mem")

    total_elapsed = (Time.now - total_start).round(1)

    log.("")
    log.("=" * 60)
    log.("IMPORT COMPLETE — #{total_elapsed}s total")
    log.("=" * 60)
    log.("")

    # Summary table
    ok = results.count { |r| r[:status] == :ok }
    failed = results.count { |r| r[:status] == :failed }
    log.("Results: #{ok} succeeded, #{failed} failed, #{results.size} total")
    log.("")

    results.each do |r|
      status = r[:status] == :ok ? "✓" : "✗"
      line = "  #{status} #{r[:task].ljust(25)} #{r[:elapsed].to_s.rjust(8)}s"
      line += "  ERROR: #{r[:error]}" if r[:error]
      log.(line)
    end

    log.("")
    log.("Full log: #{log_file}")

    # Final row counts
    log.("")
    log.("Final row counts:")
    %w[works work_units canonical_works canonical_refs words lemmas
       alignment_groups cross_references versification_mappings
       variant_units readings manuscripts pericopes work_unit_notes].each do |table|
      count = ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{table}").to_i rescue 0
      log.("  #{table.ljust(30)} #{count.to_s.rjust(10)}")
    end
  end
end
