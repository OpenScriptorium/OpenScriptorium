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

    def fix_lemma_roots!
      conn = ApplicationRecord.connection

      # For each Strong's number, find the lemma and update if the root differs
      @strongs_to_root.each do |strongs_key, data|
        # Find words with this Strong's number
        prefix = strongs_key[0]
        number = strongs_key[1..]

        # Find lemmas linked to words with this Strong's number
        lemma_ids = conn.select_values(<<~SQL)
          SELECT DISTINCT w.lemma_id
          FROM words w
          WHERE w.strongs_number = '#{number}'
            AND w.lemma_id IS NOT NULL
        SQL

        next if lemma_ids.empty?

        # Check if we already have a root lemma
        root = data[:root]
        root_normalized = root.unicode_normalize(:nfd)
                              .gsub(/[\u0300-\u036F\u0591-\u05BD\u05BF-\u05C7]/, "")

        existing_root = Lemma.find_by(lemma: root)
        existing_root ||= Lemma.find_by(normalized: root_normalized)

        if existing_root
          # Point all words to the existing root lemma
          Word.where(strongs_number: number, lemma_id: lemma_ids)
              .where.not(lemma_id: existing_root.id)
              .update_all(lemma_id: existing_root.id)
          bump :words_relinked
        else
          # Update the most-used lemma to be the root form
          primary_lemma_id = conn.select_value(<<~SQL)
            SELECT lemma_id FROM words
            WHERE strongs_number = '#{number}' AND lemma_id IS NOT NULL
            GROUP BY lemma_id ORDER BY COUNT(*) DESC LIMIT 1
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
