require "nokogiri"

module Importers
  class MaculaLemmaFixImporter < BaseImporter
    HEBREW_DIR = Rails.root.join("tmp/macula-hebrew/WLC/lowfat")
    GREEK_DIR  = Rails.root.join("tmp/macula-greek/Nestle1904/lowfat")

    def source_url
      "local:tmp/macula-{hebrew,greek}/*/lowfat"
    end

    def perform
      # Phase 1: Build Strong's → root lemma mapping from Macula
      @strongs_to_root = {}
      @domain_data = {}  # word_xml_id → {sdbh, lexdomain, coredomain}

      Rails.logger.info "[MaculaLemmaFix] Scanning Hebrew XML for root lemmas + domains..."
      scan_files(HEBREW_DIR, "H")
      Rails.logger.info "[MaculaLemmaFix] Scanning Greek XML for root lemmas + domains..."
      scan_files(GREEK_DIR, "G")

      Rails.logger.info "[MaculaLemmaFix] Found #{@strongs_to_root.size} Strong's → root mappings"

      # Phase 2: Update lemmas with correct root forms
      fix_lemma_roots!

      # Phase 3: Update words with domain codes
      apply_domain_codes!
    end

    private

    def scan_files(dir, lang_prefix)
      return unless dir.exist?

      Dir.glob(dir.join("*.xml")).sort.each do |path|
        doc = Nokogiri::XML(File.read(path))
        doc.css("w").each do |w|
          strongs = w["strongnumberx"]
          root_lemma = w["stronglemma"] || w["lemma"]
          next unless strongs && root_lemma

          key = "#{lang_prefix}#{strongs}"
          # Keep the first (most common) root form
          @strongs_to_root[key] ||= {
            root: root_lemma,
            gloss: w["english"] || w["gloss"],
            pos: w["pos"],
            transliteration: w["transliteration"]
          }

          # Collect domain data keyed by ref+position
          ref = w["ref"]
          if ref && (w["sdbh"] || w["lexdomain"] || w["coredomain"])
            @domain_data[ref] = {
              sdbh: w["sdbh"],
              lexdomain: w["lexdomain"],
              coredomain: w["coredomain"]
            }
          end

          bump :words_scanned
        end
      end
    end

    # `words.strongs_number` is stored as the bare number ("1078") without
    # the H/G prefix that distinguishes Hebrew Strong's H1078 from Greek
    # G1078. Every query in this method must scope by the language of the
    # owning Work — otherwise the bare-number match collides Hebrew and
    # Greek, ending up with Greek words pointing at Hebrew lemmas (and the
    # primary_lemma_id fallback then overwrites a Hebrew lemma's text with
    # a Greek string, corrupting that row's data).
    GREEK_LANGS  = %w[el-koine grc].freeze
    HEBREW_LANGS = %w[hbo he arc].freeze

    def fix_lemma_roots!
      conn = ApplicationRecord.connection

      # For each Strong's number, find the lemma and update if the root differs
      @strongs_to_root.each do |strongs_key, data|
        # Find words with this Strong's number
        prefix = strongs_key[0]   # "G" (Greek) or "H" (Hebrew/Aramaic)
        number = strongs_key[1..] # bare digits

        target_langs = (prefix == "G") ? GREEK_LANGS : HEBREW_LANGS
        lang_list = target_langs.map { |l| conn.quote(l) }.join(",")

        # Find lemmas linked to words with this Strong's number, scoped to
        # works in the right language.
        lemma_ids = conn.select_values(<<~SQL)
          SELECT DISTINCT w.lemma_id
          FROM words w
          JOIN works wk ON wk.id = w.work_id
          WHERE w.strongs_number = '#{number}'
            AND w.lemma_id IS NOT NULL
            AND wk.language IN (#{lang_list})
        SQL

        # NOTE: don't early-return on `lemma_ids.empty?` here — even if no
        # words are currently bound to a lemma for this Strong's (e.g.
        # they were NULLed by the cleanup migration), the existing_root
        # lookup below can still bind them via the new NULL-words path.

        # Check if we already have a root lemma
        root = data[:root]
        root_normalized = root.unicode_normalize(:nfd)
                              .gsub(/[\u0300-\u036F\u0591-\u05BD\u05BF-\u05C7]/, "")

        # Look up the canonical lemma — also language-scoped, so a
        # corrupted lemma row whose `lemma` column was overwritten with
        # the wrong-script text in a prior bad run can't be picked up
        # here and propagated forward.
        existing_root = Lemma.where(language: target_langs).find_by(lemma: root)
        existing_root ||= Lemma.where(language: target_langs).find_by(normalized: root_normalized)

        # When NO lemma exists for this Strong's at all (neither matching
        # the Macula root nor anchored by any clean word), CREATE one
        # from the Macula data. This is the only way to bind the ~272
        # WLC Hebrew words whose Strong's was wiped by the cleanup
        # migration but whose lemma never made it into StepLexicon.
        if existing_root.nil? && lemma_ids.empty?
          null_count = Word.where(strongs_number: number, lemma_id: nil)
                           .joins("JOIN works wk ON wk.id = words.work_id")
                           .where("wk.language IN (#{lang_list})")
                           .count
          if null_count > 0
            existing_root = Lemma.new(
              language:        target_langs.first,
              lemma:           root,
              normalized:      root_normalized,
              primary_gloss:   data[:gloss],
              transliteration: data[:transliteration],
              frequency:       null_count
            )
            stamp(existing_root)
            existing_root.save!
            bump :lemmas_created
          end
        end

        # Bind any NULL-lemma_id words for this Strong's to the canonical.
        # Catches words that the cleanup migration NULLed (cross-language
        # pointers cleared) where no other clean source had this Strong's
        # bound. Macula's stronglemma is authoritative — if we have a
        # matching language-scoped Lemma, use it.
        if existing_root
          null_bound = Word.where(strongs_number: number, lemma_id: nil)
                           .joins("JOIN works wk ON wk.id = words.work_id")
                           .where("wk.language IN (#{lang_list})")
                           .update_all(lemma_id: existing_root.id)
          bump(:null_words_bound, null_bound) if null_bound > 0
        end

        next if lemma_ids.empty?

        if existing_root
          # Point all language-correct words to the existing root lemma.
          # The lemma_id IN (...) restriction keeps us from sweeping in
          # cross-language words that happen to share the bare number.
          Word.where(strongs_number: number, lemma_id: lemma_ids)
              .where.not(lemma_id: existing_root.id)
              .update_all(lemma_id: existing_root.id)
          bump :words_relinked
        else
          # Update the most-used (language-correct) lemma to be the root
          # form. Without the language scope this would happily overwrite
          # a Hebrew lemma row with a Greek string (or vice versa).
          primary_lemma_id = conn.select_value(<<~SQL)
            SELECT w.lemma_id
            FROM words w
            JOIN works wk ON wk.id = w.work_id
            JOIN lemmas l  ON l.id  = w.lemma_id
            WHERE w.strongs_number = '#{number}'
              AND wk.language IN (#{lang_list})
              AND l.language  IN (#{lang_list})
              AND w.lemma_id IS NOT NULL
            GROUP BY w.lemma_id ORDER BY COUNT(*) DESC LIMIT 1
          SQL

          if primary_lemma_id
            lemma = Lemma.find(primary_lemma_id)
            lemma.update!(
              lemma: root,
              normalized: root_normalized,
              primary_gloss: data[:gloss] || lemma.primary_gloss,
              transliteration: data[:transliteration] || lemma.transliteration
            )

            # Relink other lemmas' words to this one
            Word.where(strongs_number: number, lemma_id: lemma_ids)
                .where.not(lemma_id: primary_lemma_id)
                .update_all(lemma_id: primary_lemma_id)
            bump :lemmas_fixed
          end
        end

        bump :strongs_processed
      end
    end

    def apply_domain_codes!
      # This will be done in task #35
      Rails.logger.info "[MaculaLemmaFix] Domain codes collected: #{@domain_data.size} (applied in separate task)"
    end
  end
end
