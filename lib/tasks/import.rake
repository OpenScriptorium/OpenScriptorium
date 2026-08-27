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

  desc "Import the LXX morphology dataset (word-level lemma/parsing/pos for Rahlfs LXX). " \
       "Clones github.com/OpenScriptorium/lxx-morph at job start; set LXX_MORPH_PATH to use a local checkout."
  task lxx_morph: :environment do
    Importers::LxxMorphImporter.new.call
  end

  desc "Import STEPBible TBESG (Brief Greek lexicon, CC BY 4.0). Populates Lemma.primary_gloss " \
       "for el-koine lemmas that don't already have one. Set TBESG_PATH to skip the download."
  task tbesg: :environment do
    Importers::TbesgImporter.new.call
  end

  desc "Apply the editorial lemma-gloss seed at db/seeds/lemma_glosses.json. " \
       "Fills in primary_gloss for lemmas the automated lexicon passes couldn't reach. " \
       "Set OVERRIDE=true to replace existing glosses."
  task lemma_glosses: :environment do
    Importers::LemmaGlossesImporter.new.call
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

  desc "Import the CNTR Statistical Restoration Greek NT (CC BY 4.0)"
  task cntr_sr: :environment do
    Importers::CntrSrImporter.new.call
  end

  desc "Import OpenBible.info cross-references (CC BY 4.0, ~344k links)"
  task openbible_xrefs: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::OpenbibleXrefsImporter.new(download: download).call
  end

  desc "Import OpenBible.info Topics (CC BY 4.0, ~71k topic-verse pairs; editorially filtered, see config/openbible_blacklist.yml)"
  task openbible_topics: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::OpenbibleTopicsImporter.new(download: download).call
  end

  desc "Import Sefaria Topics, Tanakh-only refs (CC BY 4.0; per-topic API calls, cached under tmp/sefaria_topics/refs/. REFRESH=true to re-fetch)"
  task sefaria_topics: :environment do
    refresh = ENV["REFRESH"] == "true"
    Importers::SefariaTopicsImporter.new(refresh: refresh).call
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

  desc "Import STEPBible TBESG/TBESH brief lexicons as structured lexicon_entries (CC BY 4.0)"
  task step_lexicon_entries: :environment do
    Importers::StepLexiconEntriesImporter.new.call
  end

  desc "Import Brown-Driver-Briggs Hebrew Lexicon (CC BY 4.0; PD BDB content from openscriptures/HebrewLexicon)"
  task bdb: :environment do
    download = ENV["DOWNLOAD"] != "false"
    Importers::BdbImporter.new(download: download).call
  end

  desc "Import Liddell-Scott-Jones Greek Lexicon (CC BY-SA 4.0 from PerseusDL/lexica). Requires sparse-checkout of LSJ TEI XML at tmp/lsj_src/."
  task lsj: :environment do
    Importers::LsjImporter.new.call
  end

  desc "Clone Clear-Bible/macula-{hebrew,greek} into tmp/ (prerequisite for macula_lemma_fix etc.)"
  task macula_download: :environment do
    # Self-contained prerequisite for any importer that reads from
    # tmp/macula-{hebrew,greek}/. Idempotent — skips if the dir already
    # exists and has content. Macula data is ~2.7 GB total; the --depth 1
    # shallow clone keeps it ~1.5 GB lighter than full history.
    repos = {
      "macula-hebrew" => "https://github.com/Clear-Bible/macula-hebrew.git",
      "macula-greek"  => "https://github.com/Clear-Bible/macula-greek.git",
    }
    repos.each do |name, url|
      target = Rails.root.join("tmp", name)
      if target.directory? && target.children.any?
        puts "#{name}: already populated at #{target} — skipping clone"
        next
      end
      target.dirname.mkpath
      puts "Cloning #{url} → #{target} (--depth 1)..."
      ok = system("git", "clone", "--depth", "1", url, target.to_s)
      abort "Clone failed: #{name}" unless ok
    end
    # Sanity check the layouts the lemma-fix importer expects.
    %w[macula-hebrew/WLC/lowfat macula-greek/Nestle1904/lowfat].each do |sub|
      path = Rails.root.join("tmp", sub)
      n = path.directory? ? path.children.size : 0
      puts "  #{sub}: #{n} files"
      abort "Expected XML files in #{path}" if n.zero?
    end
  end

  desc "Fix Hebrew/Greek lemmas to root forms using Macula stronglemma data"
  task macula_lemma_fix: :environment do
    unless Rails.root.join("tmp/macula-hebrew/WLC/lowfat").directory? &&
           Rails.root.join("tmp/macula-greek/Nestle1904/lowfat").directory?
      abort "Macula source files missing — run `rake import:macula_download` first."
    end
    Importers::MaculaLemmaFixImporter.new.call
  end

  desc "Polish lemma bindings: prefer StepLexicon dictionary lemmas over BSB inflected-form placeholders. DRY_RUN=1 to preview."
  task consolidate_lemma_canonicals: :environment do
    # Phase 2 of the lemma cleanup. After rebind_lemmas_by_strongs lands
    # words on whichever Greek/Hebrew lemma was most-used, this task
    # promotes proper StepLexicon dictionary headwords (with gloss,
    # senses, etymology) over BSB-imported placeholders (lowercase
    # surface forms with no metadata) within each Strong's group.
    #
    # Idempotent. Re-running on a clean DB does no work.
    # Set DRY_RUN=1 to print the proposed remap without writing.

    dry_run = ENV["DRY_RUN"] == "1"
    conn = ActiveRecord::Base.connection
    greek_langs  = %w[el-koine grc]
    hebrew_langs = %w[hbo he arc]

    norm_strongs = ->(s) {
      s = s.to_s
      return nil if s.empty?
      first = s.split(",").first
      first = first.sub(/\A[GHgh]/, "")
      first = first[0..-2] if first.length == 5 && first =~ /\A\d+\z/
      n = first.to_i
      return nil if n <= 0
      n.to_s
    }

    step_lexicon_run_ids = ImportRun.where(importer_class: "Importers::StepLexiconImporter").pluck(:id).to_set
    bsb_tables_run_ids   = ImportRun.where(importer_class: "Importers::BsbTablesImporter").pluck(:id).to_set

    # Score a lemma row by data completeness. Higher = better canonical.
    score = ->(row) {
      s = 0
      s += 10 if row["primary_gloss"].to_s.strip.size > 0
      senses = row["senses"]
      senses_str = senses.is_a?(String) ? senses : senses.to_s
      s += 10 if senses_str.size > 2 && senses_str != "[]" && senses_str != "null"
      s += 5  if row["etymology"].to_s.strip.size > 0
      run_id = row["import_run_id"]
      s += 5  if step_lexicon_run_ids.include?(run_id)
      s -= 3  if bsb_tables_run_ids.include?(run_id)
      lemma = row["lemma"].to_s
      # Greek: any uppercase or polytonic diacritic char (outside
      # lowercase monotonic range α-ω). Hebrew: presence of pointing.
      if lemma.match?(/[Α-Ωἀ-῿]/) || lemma.match?(/[֑-ֽֿ-ׇ]/)
        s += 2
      end
      s
    }

    [
      ["Greek",  greek_langs],
      ["Hebrew", hebrew_langs],
    ].each do |label, langs|
      lang_list = langs.map { |l| conn.quote(l) }.join(",")
      puts "\n=== #{label} consolidation ==="

      # 1. Pull all (word, lemma) pairs in this language family with a
      #    Strong's number, plus the lemma's metadata for scoring.
      puts "Loading word→lemma pairs..."
      pairs = conn.exec_query(<<~SQL).rows
        SELECT w.strongs_number, w.lemma_id, COUNT(*) AS n_words
          FROM words w
          JOIN works wk ON wk.id = w.work_id
          JOIN lemmas l ON l.id  = w.lemma_id
         WHERE wk.language IN (#{lang_list})
           AND l.language  IN (#{lang_list})
           AND w.strongs_number IS NOT NULL AND w.strongs_number <> ''
         GROUP BY w.strongs_number, w.lemma_id
      SQL

      # 2. Group by normalized Strong's. Each entry: { lemma_id => n_words }.
      groups = Hash.new { |h, k| h[k] = Hash.new(0) }
      pairs.each do |s, lid, n|
        ns = norm_strongs.call(s)
        next unless ns
        groups[ns][lid.to_i] += n.to_i
      end
      puts "  Strong's groups: #{groups.size}, multi-lemma groups: #{groups.count { |_, h| h.size > 1 }}"

      # 3. Score lemmas in multi-lemma groups, pick canonical, build remap.
      multi = groups.select { |_, h| h.size > 1 }
      lemma_ids = multi.values.flat_map(&:keys).uniq
      next if lemma_ids.empty?

      puts "Loading lemma metadata for #{lemma_ids.size} candidate rows..."
      meta = conn.exec_query(<<~SQL).to_a.index_by { |r| r["id"].to_i }
        SELECT id, lemma, primary_gloss, senses::text AS senses,
               etymology, import_run_id
          FROM lemmas
         WHERE id IN (#{lemma_ids.join(",")})
      SQL

      remap = {}              # alternate_id => canonical_id
      promotions_by_kind = Hash.new(0)
      sample_promotions = []

      multi.each do |strongs, candidates|
        scored = candidates.map do |lid, n|
          row = meta[lid] || {}
          [lid, score.call(row), n, row["lemma"]]
        end
        # Pick the canonical lemma. Order of preference:
        #   1. Highest data-completeness score (gloss + senses + etymology + StepLexicon).
        #   2. SHORTEST lemma text — root forms beat inflected forms ("אמר" beats "אמרין",
        #      "γίνομαι" beats "γενέσεως"). Inflected forms accumulate by frequency
        #      and would otherwise win the tie via word count.
        #   3. Most words (frequency tiebreaker; only kicks in when length ties).
        #   4. Smallest id (earliest import is the historical root).
        canonical = scored.max_by do |lid, sc, n, l|
          [sc, -l.to_s.length, n, -lid]
        end
        canonical_id = canonical[0]

        scored.each do |lid, _sc, _n, _l|
          remap[lid] = canonical_id if lid != canonical_id
        end

        # Track for the dry-run summary.
        next unless sample_promotions.size < 5
        non_canon = scored.reject { |row| row[0] == canonical_id }
        if non_canon.any?
          sample_promotions << [strongs,
                                "#{canonical[3]} (id=#{canonical[0]}, score=#{canonical[1]})",
                                non_canon.map { |row| "#{row[3]} (id=#{row[0]}, score=#{row[1]}, n=#{row[2]})" }]
        end
      end

      affected_words = conn.select_value(<<~SQL).to_i
        SELECT COUNT(*) FROM words WHERE lemma_id IN (#{remap.keys.join(',')})
      SQL

      puts
      puts "  remap entries:  #{remap.size}"
      puts "  affected words: #{affected_words}"
      puts
      puts "  sample promotions:"
      sample_promotions.each do |strongs, canonical, alternates|
        puts "    Strong's #{strongs}:"
        puts "      keep:    #{canonical}"
        alternates.each { |a| puts "      promote: #{a}" }
      end

      if dry_run
        puts "  (dry run, no writes)"
        next
      end

      # 4. Bulk remap via temp table.
      puts "Applying remap..."
      conn.execute("DROP TABLE IF EXISTS tmp_lemma_canonical_remap")
      conn.execute("CREATE TEMP TABLE tmp_lemma_canonical_remap (old_id bigint PRIMARY KEY, new_id bigint NOT NULL)")
      remap.each_slice(2000) do |chunk|
        values = chunk.map { |old_id, new_id| "(#{old_id}, #{new_id})" }.join(",")
        conn.execute("INSERT INTO tmp_lemma_canonical_remap VALUES #{values}")
      end
      n = conn.update(<<~SQL)
        UPDATE words w SET lemma_id = m.new_id
          FROM tmp_lemma_canonical_remap m
         WHERE w.lemma_id = m.old_id
      SQL
      puts "  words remapped: #{n}"

      # 5. Strip the now-orphaned ids from any related_lemma_ids arrays.
      conn.execute(<<~SQL)
        UPDATE lemmas l
           SET related_lemma_ids = COALESCE((
             SELECT array_agg(DISTINCT COALESCE(m.new_id, x)::integer)
               FROM unnest(l.related_lemma_ids) x
          LEFT JOIN tmp_lemma_canonical_remap m ON m.old_id = x
           ), '{}'::integer[])
         WHERE l.related_lemma_ids && (SELECT array_agg(old_id::integer) FROM tmp_lemma_canonical_remap)
      SQL

      # 6. Delete BSB-placeholder orphans (no words point at them, came
      #    from BsbTablesImporter, are in our remap as old_ids). Skip
      #    orphans from other importers to be safe.
      bsb_run_list = bsb_tables_run_ids.to_a.join(",")
      bsb_run_list = "0" if bsb_run_list.empty?
      orphans_deleted = conn.delete(<<~SQL)
        DELETE FROM lemmas l
         WHERE l.id IN (SELECT old_id FROM tmp_lemma_canonical_remap)
           AND l.import_run_id IN (#{bsb_run_list})
           AND NOT EXISTS (SELECT 1 FROM words w WHERE w.lemma_id = l.id)
      SQL
      puts "  orphan placeholders deleted: #{orphans_deleted}"
      conn.execute("DROP TABLE IF EXISTS tmp_lemma_canonical_remap")
    end
  end

  desc "Rebind Greek/Hebrew words.lemma_id by Strong's number using existing clean lemmas (no Macula download required)"
  task rebind_lemmas_by_strongs: :environment do
    # Self-contained one-shot fix: after the cleanup migration NULLed
    # ~218K Greek and ~6K Hebrew word→lemma pointers (corruption from
    # the old MaculaLemmaFixImporter bug), this task repopulates them
    # from clean lemmas already in the DB. No Macula download needed.
    #
    # Strong's number is stored inconsistently across importers:
    #   - nestle1904, rp:        "3588" (bare integer)
    #   - cntr-sr:               "G25320" (G-prefix + 5-digit, trailing 0
    #                            marks the base entry; G25321 etc are
    #                            homonym variants for the same lemma)
    #   - kjv, patriarchal-1904: "G2532" or "G2532,G3756" (multi)
    #
    # Normalize on both sides to a common bare-integer string.
    norm_strongs = ->(s) {
      s = s.to_s
      return nil if s.empty?
      first = s.split(",").first
      first = first.sub(/\A[GHgh]/, "")
      # cntr-sr's 5-digit format: drop the trailing variant digit so
      # G25320, G25321, G25322 all collapse to base 2532.
      first = first[0..-2] if first.length == 5 && first =~ /\A\d+\z/
      first.to_i.to_s
    }

    conn = ActiveRecord::Base.connection
    greek_langs  = %w[el-koine grc]
    hebrew_langs = %w[hbo he arc]

    [
      ["Greek",  greek_langs],
      ["Hebrew", hebrew_langs],
    ].each do |label, langs|
      lang_list = langs.map { |l| conn.quote(l) }.join(",")

      puts "\n=== #{label} pass ==="

      # Pull every (clean) word→lemma pair, normalize Strong's, pick the
      # canonical lemma per normalized Strong's by total word count.
      puts "Building normalized Strong's map from clean #{label} pointers..."
      pairs = conn.exec_query(<<~SQL).rows
        SELECT w.strongs_number, w.lemma_id, COUNT(*) AS n
          FROM words w
          JOIN works wk ON wk.id = w.work_id
          JOIN lemmas l ON l.id  = w.lemma_id
         WHERE wk.language IN (#{lang_list})
           AND l.language  IN (#{lang_list})
           AND w.strongs_number IS NOT NULL AND w.strongs_number <> ''
         GROUP BY w.strongs_number, w.lemma_id
      SQL

      tally = Hash.new { |h, k| h[k] = Hash.new(0) }
      pairs.each do |s, lid, n|
        ns = norm_strongs.call(s)
        next unless ns
        tally[ns][lid.to_i] += n.to_i
      end
      strongs_to_lemma = tally.transform_values { |h| h.max_by { |_, n| n }.first }
      puts "  normalized Strong's map: #{strongs_to_lemma.size} distinct numbers"

      # Build a mapping table keyed by RAW strongs_number value, expanded
      # so the UPDATE can join by the exact column value used in `words`.
      puts "Expanding map to all known raw Strong's variants..."
      raw_to_lemma = {}
      conn.exec_query(<<~SQL).rows.each do |raw|
        SELECT DISTINCT w.strongs_number
          FROM words w
          JOIN works wk ON wk.id = w.work_id
         WHERE w.lemma_id IS NULL
           AND w.strongs_number IS NOT NULL
           AND wk.language IN (#{lang_list})
      SQL
        raw_strongs = raw.first
        ns = norm_strongs.call(raw_strongs)
        if ns && (lid = strongs_to_lemma[ns])
          raw_to_lemma[raw_strongs] = lid
        end
      end
      puts "  raw-form coverage: #{raw_to_lemma.size} variants"

      conn.execute("DROP TABLE IF EXISTS tmp_strongs_map")
      conn.execute(<<~SQL)
        CREATE TEMP TABLE tmp_strongs_map (
          strongs_number text PRIMARY KEY,
          lemma_id bigint NOT NULL
        )
      SQL
      raw_to_lemma.each_slice(2000) do |chunk|
        values = chunk.map { |s, lid| "(#{conn.quote(s)}, #{lid.to_i})" }.join(",")
        conn.execute("INSERT INTO tmp_strongs_map VALUES #{values}") unless values.empty?
      end

      n = conn.update(<<~SQL)
        UPDATE words w
           SET lemma_id = m.lemma_id
          FROM tmp_strongs_map m, works wk
         WHERE w.strongs_number = m.strongs_number
           AND w.work_id = wk.id
           AND wk.language IN (#{lang_list})
           AND w.lemma_id IS NULL
      SQL
      puts "  rebound: #{n}"
      conn.execute("DROP TABLE IF EXISTS tmp_strongs_map")

      remaining = conn.select_value(<<~SQL).to_i
        SELECT COUNT(*)
          FROM words w
          JOIN works wk ON wk.id = w.work_id
         WHERE w.lemma_id IS NULL
           AND w.strongs_number IS NOT NULL
           AND wk.language IN (#{lang_list})
      SQL
      puts "  still NULL (Strong's not in map): #{remaining}"
    end
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

  desc "Delete lemma rows with no attached words AND no lexicon entries (final cleanup after all lexicon imports)"
  task cleanup_orphan_lemmas: :environment do
    n = Lemma
      .where("NOT EXISTS (SELECT 1 FROM words WHERE words.lemma_id = lemmas.id)")
      .where("NOT EXISTS (SELECT 1 FROM lexicon_entries WHERE lexicon_entries.lemma_id = lemmas.id)")
      .delete_all
    puts "Deleted #{n} orphan lemma rows"
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
      # lxx_morph populates word-level lemma / parsing / pos for every
      # Rahlfs LXX verse from the CC BY 4.0 lxx-morph corpus.
      { name: "Versification + annotations", tasks: %w[tvtms oshb_features nestle_apparatus brenton_notes lxx_morph] },
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
      # Phase 8: Lexicon cleanup (needs all word data) — creates clean
      # dictionary lemma rows from STEPBible TSV, merges duplicates by
      # Strong's number, backfills frequencies/glosses.
      { name: "Lexicon cleanup", tasks: %w[step_lexicon] },
      # Phase 9: Macula corpus enrichment. macula_download fetches the
      # source repos (~2.7 GB); macula_lemma_fix uses Macula stronglemma
      # to rewire Hebrew/Greek words.lemma_id at root forms (and create
      # roots that StepLexicon missed); the trio of participants/domains/
      # syntax adds Macula's coreference, semantic-domain, and syntax-tree
      # data referencing those words.
      { name: "Macula download",      tasks: %w[macula_download] },
      { name: "Macula lemma fix",     tasks: %w[macula_lemma_fix] },
      { name: "Macula enrichments",   tasks: %w[macula_participants macula_domains macula_syntax], parallel: true },
      # Phase 10: Lexicon entries (BDB, LSJ, STEPBible structured bodies).
      # All key off existing lemmas, so they must run after step_lexicon
      # and macula_lemma_fix have finalized the lemma set.
      { name: "Lexicon entries",      tasks: %w[bdb lsj step_lexicon_entries tbesg], parallel: true },
      # Phase 11: Passage aliases (named passages, parables, events).
      # Depends on canonical_works/canonical_refs from earlier phases.
      { name: "Passage aliases",      tasks: %w[passage_aliases] },
      # ─── Lemma cleanup chain ─────────────────────────────────────────────
      # All steps below run AFTER bdb / lsj / step_lexicon_entries so the
      # lemma set is complete and we have rich LexiconEntry data to draw
      # from. Order matters — each step's input is the previous step's
      # output. See lib/tasks/*.rake for per-task incident writeups.
      #
      #   1. rebind_multi_token   — undo StepLexicon's collapse of distinct
      #                              Strong's onto shared multi-word
      #                              headwords (Beth-jeshimoth absorbing
      #                              H1004 "house" uses, Ζεύς absorbing
      #                              G1223 διά, אֲדֹנִי־צֶ֫דֶק absorbing
      #                              H113 "lord", etc.).
      #   2. split_homonyms       — split lemmas whose bound Words have
      #                              widely-separated Strong's (Hebrew
      #                              homonyms like נֵר "lamp" H5216 vs
      #                              "Ner" H5369). Requires the drop-
      #                              unique-index migration.
      #   3. fix_parenthetical_glosses — clean up "(Place of) X" style
      #                              gloss residue from TBESH's
      #                              place-modifier rows.
      #   4. relink_words         — bind the ~700 KJV orphan Strong's the
      #                              importer's per-row lookup missed.
      #   5. bind_clitic_prepositions — bind WLC's ~6k preposition+suffix
      #                              tokens (לוֹ, בוֹ, …) to clitic-
      #                              preposition lemmas H9001-H9008.
      #   6. resolve_null_strongs_by_surface — bind 64-ish patriarchal-1904
      #                              Greek tokens (κατ᾽, Θεοῦ, …) to
      #                              existing lemmas via diacritic-stripped
      #                              surface match.
      #   7. backfill_from_lexicon_entries — fill primary_gloss /
      #                              transliteration from linked
      #                              LexEntries.
      #   8. backfill_part_of_speech — fill part_of_speech from Word
      #                              morph_codes + LexEntries +
      #                              TBESH/TBESG.
      #   9. lsj_metadata_backfill — for Greek lemmas still missing POS
      #                              or transliteration, classify by
      #                              ending and Romanize.
      #  10. backfill_homonym_siblings — fill metadata for the per-Strong's
      #                              sibling lemmas created in step 2.
      #  11. refresh_frequency    — recompute per-lemma frequency counts
      #                              after every prior step has moved Words.
      { name: "Lemma cleanup", tasks: %w[
          lemmas:rebind_multi_token
          lemmas:split_homonyms
          lemmas:fix_parenthetical_glosses
          lemmas:relink_words
          lemmas:bind_clitic_prepositions
          lemmas:resolve_null_strongs_by_surface
          lemmas:backfill_from_lexicon_entries
          lemmas:backfill_part_of_speech
          lemmas:lsj_metadata_backfill
          lemmas:backfill_homonym_siblings
          lemmas:reconcile_lsj
          lemmas:cross_link_hebrew
          import:lemma_glosses
          lemmas:refresh_frequency
        ] },
      # Final orphan cleanup runs AFTER all the rebinding passes — they
      # may strand lemmas with no Words and no LexiconEntries (e.g. the
      # 169 transient rows the integrity rebind creates and then empties).
      { name: "Orphan cleanup",       tasks: %w[cleanup_orphan_lemmas] },
      # Topical themes (CC BY 4.0 datasets used by topic search).
      # openbible_topics is fast (single TSV); sefaria_topics fetches per-
      # topic via Sefaria's API on first run (~13 min) and caches under
      # tmp/sefaria_topics/refs/ for subsequent runs.
      { name: "Topical themes",       tasks: %w[openbible_topics sefaria_topics] },
    ]

    # Non-essential indexes to drop before import and rebuild after.
    # These slow down inserts significantly (especially GIN/GIST).
    # Primary keys, unique constraints, and foreign keys are kept.
    DROPPABLE_INDEXES = %w[
      idx_work_units_body_tsvector
      index_words_on_strongs_number
      idx_lemmas_gloss_fts
      idx_lemmas_normalized_trgm
      idx_lemmas_transliteration_trgm
      idx_lemmas_primary_gloss_trgm
      idx_lemmas_senses_fts
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
        # Task names without an explicit namespace are resolved under
        # import:. Names like "lemmas:relink_words" run as-is so we can
        # mix post-import cleanup tasks (lemmas: namespace) into the
        # pipeline.
        full_name = task_name.include?(":") ? task_name : "import:#{task_name}"
        log.("  Starting #{full_name}...")
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

          Rake::Task[full_name].invoke

          elapsed = (Time.now - task_start).round(1)

          # Snapshot row counts after
          deltas = []
          counts_before.each do |table, before|
            after = ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM #{table}").to_i rescue 0
            diff = after - before
            deltas << "#{table}:+#{diff}" if diff > 0
          end

          log.("  ✓ #{full_name} completed in #{elapsed}s")
          log.("    Rows added: #{deltas.any? ? deltas.join(', ') : 'none'}") if deltas.any?
          mutex.synchronize { results << { task: task_name, status: :ok, elapsed: elapsed, deltas: deltas } }
        rescue => e
          elapsed = (Time.now - task_start).round(1)
          log.("  ✗ #{full_name} FAILED in #{elapsed}s: #{e.class}: #{e.message}")
          log.("    #{e.backtrace.first(3).join("\n    ")}")
          mutex.synchronize { results << { task: task_name, status: :failed, elapsed: elapsed, error: e.message } }
        ensure
          Rake::Task[full_name].reenable
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

    # Refresh the per-Work feature flag cache (NTS/LEM/STR/PRS/ALN/PRC/QUO/APP).
    # The works index page reads cached_feature_flags directly to keep page
    # rendering fast; importers that added notes, lemmas, parsing etc. won't
    # be reflected on /works until this runs.
    log.("Refreshing Work#cached_feature_flags...")
    Work.refresh_all_feature_flags!
    log.("  done")

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
