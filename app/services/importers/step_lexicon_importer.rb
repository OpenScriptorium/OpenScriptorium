module Importers
  # Imports STEP Bible lexicon data (TBESH + TBESG) from Tyndale House
  # Cambridge. These provide clean English glosses, transliterations,
  # morphological classifications, and structured definitions mapped to
  # Extended Strong's numbers.
  #
  # This importer:
  # 1. Creates/updates Lemma records with authoritative lexical data
  # 2. Uses the dictionary headword from STEP as the canonical lemma form
  # 3. Deduplicates: merges surface-form-based lemmas into one canonical
  #    lemma per Strong's number, reassigning words.lemma_id
  # 4. Backfills frequency counts from actual word occurrences
  #
  # Source: STEPBible-Data/Lexicons (CC BY 4.0, Tyndale House Cambridge)
  # License: CC BY 4.0 — free software compatible.
  class StepLexiconImporter < BaseImporter
    DEFAULT_DIR = Rails.root.join("tmp/stepbible")

    HEBREW_FILE = "TBESH.txt"
    GREEK_FILE  = "TBESG.txt"

    # STEP morph language prefixes → our language codes
    LANG_MAP = {
      "H" => "he",
      "A" => "arc",
      "G" => "el-koine",
      "N" => nil  # proper nouns — determine from Strong's prefix
    }.freeze

    def source_url
      "https://github.com/STEPBible/STEPBible-Data/tree/master/Lexicons"
    end

    def source_format
      "tsv"
    end

    def transactional?
      false # ~21K rows, incremental commits
    end

    protected

    def perform
      @dir = @opts[:dir] || DEFAULT_DIR

      import_file(File.join(@dir, HEBREW_FILE), default_language: "he")
      import_file(File.join(@dir, GREEK_FILE), default_language: "el-koine")

      cleanup_orphans
      backfill_frequencies
      cleanup_glosses
    end

    private

    def import_file(path, default_language:)
      unless File.exist?(path)
        Rails.logger.warn "[StepLexiconImporter] file not found: #{path}"
        return
      end

      Rails.logger.info "[StepLexiconImporter] processing #{path}"
      in_data = false

      File.foreach(path, encoding: "utf-8") do |line|
        line = line.strip

        # Detect the column header row to know when data starts
        if line.start_with?("eStrong#\t")
          in_data = true
          next
        end
        next unless in_data
        next if line.blank? || line.start_with?("#")

        process_row(line, default_language)
      end
    end

    def process_row(line, default_language)
      cols = line.split("\t", -1)
      return if cols.size < 7

      e_strong  = cols[0].strip  # e.g., "H0001", "G3056"
      d_strong  = cols[1].strip  # disambiguated Strong's
      u_strong  = cols[2].strip  # unified Strong's
      headword  = cols[3].strip  # dictionary form in original script
      translit  = cols[4].strip  # transliteration
      morph     = cols[5].strip  # e.g., "H:N-M", "G:V"
      gloss     = cols[6].strip  # short English gloss from Tyndale scholars
      meaning   = cols[7]&.strip # full definition (may be absent)

      if e_strong.blank?
        bump(:rows_blank_strongs)
        return
      end

      # If headword is blank, try to recover from the base Strong's entry
      # (STEP disambiguated entries like G2199H sometimes have empty headword)
      if headword.blank?
        base_strongs = e_strong.sub(/[A-Z]\z/, "")  # G2199H → G2199
        if base_strongs != e_strong
          base_lemma = Lemma.joins(:words).where(words: { strongs_number: normalize_strongs(base_strongs) })
                            .where.not(lemma: [nil, ""]).first
          headword = base_lemma&.lemma.to_s.strip
        end
        if headword.blank?
          bump(:rows_blank_headword)
          return
        end
        bump(:rows_headword_recovered)
      end

      # Determine language from morph prefix or Strong's number
      language = language_from_morph(morph) ||
                 language_from_strongs(e_strong) ||
                 default_language

      # Normalize the Strong's number to match what words.strongs_number stores.
      # Our words table stores "H430", "G3056" etc. (no leading zeros).
      norm_strongs = normalize_strongs(e_strong)

      # Clean up the gloss and meaning
      clean_gloss = clean_text(gloss)
      clean_meaning = meaning.present? ? clean_html_meaning(meaning) : nil

      # Parse morph into a simple POS string
      pos = parse_pos(morph)

      # Find or create the canonical lemma for this Strong's number
      canonical = find_or_create_canonical_lemma(
        language: language,
        headword: headword,
        norm_strongs: norm_strongs,
        transliteration: translit.presence,
        gloss: clean_gloss,
        meaning: clean_meaning,
        pos: pos,
        d_strong: d_strong,
        u_strong: u_strong
      )

      if canonical
        bump(:lemmas_processed)
      else
        bump(:lemmas_skipped)
      end
    end

    def find_or_create_canonical_lemma(language:, headword:, norm_strongs:, transliteration:,
                                        gloss:, meaning:, pos:, d_strong:, u_strong:)
      # Strategy: Strong's number is the primary identity key. Different
      # Strong's numbers = different lemmas, even if they share the same
      # consonantal skeleton (e.g., H1285 berith "covenant" vs H1287 borit "lye"
      # both normalize to ברית but are different words).
      #
      # 1. Find lemmas linked to THIS Strong's number via words
      # 2. Among those, pick the best one (has gloss, most words)
      # 3. Only fall back to headword/normalized match if no Strong's link exists
      # 4. Never merge a lemma that is linked to a DIFFERENT Strong's number

      normalized_hw = normalize_script(headword, language)

      # Find lemmas currently linked to this Strong's via words
      linked_lemma_ids = Word.where(strongs_number: norm_strongs)
                             .where.not(lemma_id: nil)
                             .distinct
                             .pluck(:lemma_id)

      canonical = nil

      if linked_lemma_ids.any?
        # Pick the best lemma among those linked to this Strong's number
        canonical = Lemma.where(id: linked_lemma_ids)
                         .select("lemmas.*, (SELECT COUNT(*) FROM words WHERE words.lemma_id = lemmas.id) AS wc")
                         .order(Arel.sql("CASE WHEN primary_gloss IS NOT NULL AND primary_gloss != '' THEN 0 ELSE 1 END, wc DESC"))
                         .first
      end

      if canonical.nil?
        # No words with this Strong's — try exact headword match, but only
        # if that lemma isn't already linked to a DIFFERENT Strong's number.
        candidate = Lemma.find_by(language: language, lemma: headword)
        if candidate && !linked_to_different_strongs?(candidate, norm_strongs)
          canonical = candidate
        end
      end

      if canonical.nil?
        # Try normalized match, same guard
        candidate = Lemma.find_by(language: language, normalized: normalized_hw)
        if candidate && !linked_to_different_strongs?(candidate, norm_strongs)
          canonical = candidate
        end
      end

      if canonical.nil?
        # Create new lemma for this Strong's number
        canonical = Lemma.new(language: language, lemma: headword, normalized: normalized_hw)
        stamp(canonical)
        bump(:lemmas_created)
      else
        bump(:lemmas_updated)
      end

      # Update with STEP data (STEP is authoritative, overwrite old Strong's junk)
      canonical.lemma = headword
      canonical.normalized = normalized_hw
      canonical.transliteration = transliteration if transliteration.present?
      canonical.part_of_speech = pos if pos.present?

      # For glosses: prefer common-word glosses (lowercase) over proper
      # names (capitalized). When multiple STEP rows share a headword
      # (e.g., H5828 "helper" and H5829 "Ezer"), keep the common word.
      # Merge disambiguated common-word glosses (e.g., "beginning" + "best").
      if gloss.present?
        existing_gloss = canonical.primary_gloss.to_s.strip
        new_is_proper = gloss.match?(/\A[A-Z]/)
        existing_is_common = existing_gloss.present? && existing_gloss.match?(/\A[a-z]/)

        if existing_gloss.blank?
          canonical.primary_gloss = gloss
        elsif existing_is_common && new_is_proper
          # Don't overwrite "helper" with "Ezer" — skip
        elsif !existing_is_common && !new_is_proper
          # Replace old junk/proper name with a common-word gloss
          canonical.primary_gloss = gloss
        elsif !existing_gloss.include?(gloss)
          # Both common words — merge: "first: beginning" + "first: best"
          canonical.primary_gloss = "#{existing_gloss}; #{gloss}"
        end
      end

      # Store the structured meaning in senses (append, don't overwrite)
      if meaning.present?
        new_senses = parse_senses(meaning)
        existing = canonical.senses || []
        canonical.senses = existing + new_senses
      end

      stamp(canonical)
      canonical.save!

      # Merge: reassign ONLY words with this Strong's number from other
      # lemmas to the canonical one. Do NOT reassign words with different
      # Strong's numbers — those belong to a different lexical entry.
      other_ids = linked_lemma_ids - [canonical.id]
      if other_ids.any?
        merged = Word.where(lemma_id: other_ids)
                     .where(strongs_number: norm_strongs)
                     .update_all(lemma_id: canonical.id)
        bump(:words_reassigned, merged)

        # Delete orphaned lemmas only if they have no remaining words at all
        orphans = Lemma.where(id: other_ids)
                       .where("NOT EXISTS (SELECT 1 FROM words WHERE words.lemma_id = lemmas.id)")
        orphan_count = orphans.count
        orphans.destroy_all
        bump(:duplicates_removed, orphan_count)
      end

      canonical
    rescue ActiveRecord::RecordInvalid => e
      # Uniqueness violation — the same headword already exists for this
      # language. Common for Aramaic words that share headword text with
      # Hebrew entries. Find and reuse the existing record, updating its
      # gloss if ours is better.
      # Try exact match, then related languages (Aramaic/Hebrew share headwords),
      # then any language. Use uncached query to catch records created earlier in this run.
      existing = Lemma.where(lemma: headword).where(language: [language, "he", "arc", "hbo"]).first ||
                 Lemma.where(lemma: headword).first
      if existing
        if gloss.present? && (existing.primary_gloss.blank? || existing.primary_gloss.match?(/\A[A-Z]/))
          existing.update(primary_gloss: gloss, transliteration: transliteration || existing.transliteration)
        end
        bump(:lemmas_reused_existing)
        return existing
      end
      $stdout.puts "[StepLexiconImporter] ERROR: #{headword} (#{norm_strongs}, #{language}): #{e.message}"
      $stdout.flush
      Rails.logger.warn "[StepLexiconImporter] skipping #{headword}: #{e.message}"
      bump(:lemmas_errored)
      nil
    end

    def cleanup_orphans
      # Remove lemmas that have zero words attached and were NOT created
      # by this importer. These are junk surface-form placeholders left
      # over from older importers that are no longer the source of truth.
      # Legitimate STEP-created lemmas (lexicon entries for words not yet
      # in the corpus) are kept.
      step_run_ids = ImportRun.where(importer_class: "Importers::StepLexiconImporter").pluck(:id)

      orphans = Lemma
        .where("NOT EXISTS (SELECT 1 FROM words WHERE words.lemma_id = lemmas.id)")
        .where.not(import_run_id: step_run_ids)

      count = orphans.count
      orphans.delete_all
      bump(:orphans_cleaned, count)
      Rails.logger.info "[StepLexiconImporter] cleaned #{count} orphan lemmas"
    end

    # Check if a lemma is already linked to words with a Strong's number
    # different from the one we're processing. If so, merging would corrupt
    # the data (e.g., merging "lye" H1287 into "covenant" H1285).
    def linked_to_different_strongs?(lemma, norm_strongs)
      return false if norm_strongs.blank?
      existing_strongs = Word.where(lemma_id: lemma.id)
                             .where.not(strongs_number: [nil, ""])
                             .distinct
                             .pluck(:strongs_number)
      return false if existing_strongs.empty?
      !existing_strongs.include?(norm_strongs)
    end

    def backfill_frequencies
      Rails.logger.info "[StepLexiconImporter] backfilling frequencies..."

      # Bulk update: set frequency = actual word count
      ActiveRecord::Base.connection.execute(<<~SQL)
        UPDATE lemmas
        SET frequency = sub.wc
        FROM (
          SELECT lemma_id, COUNT(*) AS wc
          FROM words
          WHERE lemma_id IS NOT NULL
          GROUP BY lemma_id
        ) sub
        WHERE lemmas.id = sub.lemma_id
          AND lemmas.frequency != sub.wc
      SQL

      updated = ActiveRecord::Base.connection.select_value(
        "SELECT COUNT(*) FROM lemmas WHERE frequency > 0"
      )
      bump(:frequencies_updated, updated.to_i)
      Rails.logger.info "[StepLexiconImporter] #{updated} lemmas with frequency > 0"

      backfill_glosses_from_siblings
    end

    # Propagate glosses from STEP-imported lemmas to high-frequency
    # siblings that share the same normalized form but lack gloss data.
    # This handles cases like חסדך (freq=988, no gloss) getting the
    # gloss from חֶ֫סֶד (freq=1, STEP-imported with "be kind; kindness").
    def backfill_glosses_from_siblings
      Rails.logger.info "[StepLexiconImporter] backfilling glosses from siblings..."

      conn = ActiveRecord::Base.connection
      result = conn.execute(<<~SQL)
        UPDATE lemmas h
        SET primary_gloss = s.primary_gloss,
            transliteration = COALESCE(NULLIF(h.transliteration, ''), s.transliteration),
            part_of_speech = COALESCE(NULLIF(h.part_of_speech, ''), s.part_of_speech)
        FROM lemmas s
        WHERE s.normalized = h.normalized
          AND s.language = h.language
          AND s.id != h.id
          AND h.frequency > 10
          AND (h.primary_gloss IS NULL OR h.primary_gloss = '')
          AND s.primary_gloss IS NOT NULL AND s.primary_gloss != ''
          AND s.primary_gloss !~ '^[A-Z]'
      SQL

      count = result.cmd_tuples
      bump(:glosses_backfilled_siblings, count)
      Rails.logger.info "[StepLexiconImporter] backfilled glosses from siblings: #{count}"

      backfill_glosses_from_strongs
    end

    # Second-pass backfill: for lemmas that STILL have no gloss, find a
    # glossed lemma that shares the same Strong's number via the words table.
    # This catches inflected forms (ויאמר freq=14754) whose normalized form
    # differs from the STEP headword (אמר) but whose words carry the same
    # Strong's number.
    def backfill_glosses_from_strongs
      $stdout.puts "[StepLexiconImporter] backfilling glosses from Strong's numbers (may take a few minutes)..."
      $stdout.flush

      conn = ActiveRecord::Base.connection

      # Approach: instead of a massive self-join on words, go through
      # glossless lemmas one at a time and find a glossed lemma via
      # the strongs_number on their words. Much more predictable performance.
      glossless = conn.select_all(<<~SQL)
        SELECT l.id, l.language
        FROM lemmas l
        WHERE l.frequency > 10
          AND (l.primary_gloss IS NULL OR l.primary_gloss = '')
      SQL

      count = 0
      glossless.each do |row|
        # Find a Strong's number used by this lemma's words
        strongs = conn.select_value(<<~SQL)
          SELECT DISTINCT strongs_number FROM words
          WHERE lemma_id = #{row['id'].to_i}
            AND strongs_number IS NOT NULL
          LIMIT 1
        SQL
        next unless strongs

        # Find a glossed lemma that shares this Strong's number
        donor = conn.select_one(<<~SQL)
          SELECT l.primary_gloss, l.transliteration, l.part_of_speech
          FROM lemmas l
          JOIN words w ON w.lemma_id = l.id
          WHERE w.strongs_number = #{conn.quote(strongs)}
            AND l.id != #{row['id'].to_i}
            AND l.primary_gloss IS NOT NULL AND l.primary_gloss != ''
            AND l.primary_gloss !~ '^[A-Z]'
          ORDER BY l.frequency DESC
          LIMIT 1
        SQL
        next unless donor

        conn.execute(<<~SQL)
          UPDATE lemmas SET
            primary_gloss = #{conn.quote(donor['primary_gloss'])},
            transliteration = COALESCE(NULLIF(transliteration, ''), #{conn.quote(donor['transliteration'])}),
            part_of_speech = COALESCE(NULLIF(part_of_speech, ''), #{conn.quote(donor['part_of_speech'])})
          WHERE id = #{row['id'].to_i}
        SQL
        count += 1
      end

      bump(:glosses_backfilled_strongs, count)
      $stdout.puts "[StepLexiconImporter] backfilled glosses from Strong's: #{count}"
      $stdout.flush
    end

    # Final cleanup: strip "null" prefixes and decode HTML entities in
    # all glosses. These come from donor lemmas created by other importers
    # (bsb_tables etc.) that don't use clean_text.
    def cleanup_glosses
      $stdout.puts "[StepLexiconImporter] cleaning up glosses..."
      $stdout.flush
      conn = ActiveRecord::Base.connection

      # Strip "null" prefix
      r1 = conn.execute("UPDATE lemmas SET primary_gloss = REGEXP_REPLACE(primary_gloss, '^null', '') WHERE primary_gloss LIKE 'null%'")
      bump(:glosses_null_stripped, r1.cmd_tuples)

      # Decode HTML entities
      r2 = conn.execute("UPDATE lemmas SET primary_gloss = REGEXP_REPLACE(primary_gloss, '&#(\\d+);?', '', 'g') WHERE primary_gloss ~ '&#\\d+'")
      bump(:glosses_entities_cleaned, r2.cmd_tuples)

      # Trim whitespace
      r3 = conn.execute("UPDATE lemmas SET primary_gloss = TRIM(REGEXP_REPLACE(primary_gloss, '\\s+', ' ', 'g')) WHERE primary_gloss != TRIM(REGEXP_REPLACE(primary_gloss, '\\s+', ' ', 'g'))")
      bump(:glosses_trimmed, r3.cmd_tuples)

      $stdout.puts "[StepLexiconImporter] cleaned: #{r1.cmd_tuples} null prefixes, #{r2.cmd_tuples} entities, #{r3.cmd_tuples} trimmed"
      $stdout.flush
    end

    # --- Parsing helpers ---

    def language_from_morph(morph)
      prefix = morph.split(":").first
      LANG_MAP[prefix]
    end

    def language_from_strongs(strongs)
      case strongs[0]
      when "H" then "he"
      when "G" then "el-koine"
      end
    end

    def normalize_strongs(e_strong)
      # "H0001" → "H1", "G3056" → "G3056" (strip leading zeros after prefix)
      prefix = e_strong[0]
      num = e_strong[1..].to_i
      "#{prefix}#{num}"
    end

    def normalize_script(text, language)
      case language
      when "he", "hbo", "arc"
        # Strip Hebrew nikud/cantillation
        text.gsub(/[\u0591-\u05BD\u05BF-\u05C7]/, "")
      when "el-koine", "grc"
        # Strip Greek diacritics
        text.unicode_normalize(:nfd).gsub(/[\u0300-\u036F]/, "").unicode_normalize(:nfc)
      else
        text
      end
    end

    def clean_text(text)
      return nil if text.blank?
      result = text
        .gsub(/<[^>]+>/, "")              # strip HTML tags
        .gsub(/&#(\d+);?/) { [$1.to_i].pack("U") rescue $& }  # decode numeric entities
        .gsub(/&amp;/, "&")
        .gsub(/&lt;/, "<")
        .gsub(/&gt;/, ">")
        .gsub(/&quot;/, '"')
        .gsub(/&nbsp;/, " ")
        .gsub(/\s+/, " ")                 # collapse whitespace
        .strip
      # Strip "null" prefix (JavaScript artifact in some STEP rows)
      result = result.sub(/\Anull/, "") if result.start_with?("null")
      result.strip
    end

    def clean_html_meaning(text)
      return nil if text.blank?
      clean_text(text)
    end

    def parse_pos(morph)
      return nil if morph.blank?
      # morph format: "H:N-M" → type is "N"
      parts = morph.split(":")
      return nil if parts.size < 2
      type_part = parts[1].split("-").first
      POS_MAP[type_part] || type_part
    end

    POS_MAP = {
      "A" => "adjective", "Adv" => "adverb", "Art" => "article",
      "Cond" => "conditional", "Conj" => "conjunction",
      "Cor" => "correlative", "DemP" => "demonstrative pronoun",
      "ImpP" => "impersonal pronoun", "INJ" => "interjection",
      "Intg" => "interrogative", "Intj" => "interjection",
      "N" => "noun", "Neg" => "negative", "Part" => "particle",
      "Prep" => "preposition", "PerP" => "personal pronoun",
      "PosP" => "possessive pronoun", "RefP" => "reflexive pronoun",
      "RelP" => "relative pronoun", "V" => "verb"
    }.freeze

    def parse_senses(meaning)
      return [] if meaning.blank?
      # Split on numbered entries like "1)", "2)", "1a)"
      # Return as array of sense strings
      cleaned = clean_text(meaning)
      senses = cleaned.split(/(?=\d+[a-z]?\))/).map(&:strip).reject(&:blank?)
      senses.map { |s| { definition: s } }
    end
  end
end
