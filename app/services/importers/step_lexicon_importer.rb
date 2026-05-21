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

    SOURCE_FILE_URLS = {
      "TBESH.txt" => "https://raw.githubusercontent.com/STEPBible/STEPBible-Data/master/Lexicons/TBESH%20-%20Translators%20Brief%20lexicon%20of%20Extended%20Strongs%20for%20Hebrew%20-%20STEPBible.org%20CC%20BY.txt",
      "TBESG.txt" => "https://raw.githubusercontent.com/STEPBible/STEPBible-Data/master/Lexicons/TBESG%20-%20Translators%20Brief%20lexicon%20of%20Extended%20Strongs%20for%20Greek%20-%20STEPBible.org%20CC%20BY.txt"
    }.freeze

    def perform
      @dir = @opts[:dir] || DEFAULT_DIR
      download_source

      import_file(File.join(@dir, HEBREW_FILE), default_language: "he")
      import_file(File.join(@dir, GREEK_FILE), default_language: "el-koine")

      # Orphan cleanup deferred to a separate post-lexicon pass —
      # running it here destroys lemmas that downstream lexicon
      # importers (step_lexicon_entries / bdb / lsj) would have linked
      # to. See `import:cleanup_orphans` rake.
      backfill_frequencies
      cleanup_glosses
    end

    def download_source
      require "open-uri"
      FileUtils.mkdir_p(@dir)
      SOURCE_FILE_URLS.each do |name, url|
        path = File.join(@dir, name)
        next if File.exist?(path)
        Rails.logger.info "[StepLexiconImporter] downloading #{name}"
        File.binwrite(path, URI.open(url).read)
        bump(:source_downloaded)
      end
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
      # TBESH/TBESG lists spelling variants comma-joined ("Μωϋσῆς, Μωσῆς",
      # "Δαυείδ, Δαυίδ, Δαβίδ"). Only the first form is the canonical
      # headword; the rest are alternates. Without this trim we'd store
      # the entire comma-string as the lemma's lemma column, which both
      # reads badly in the UI and creates spurious "multi-token" lemma
      # rows that distort top-binding audits.
      headword  = headword.split(",").first.to_s.strip if headword.include?(",")
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

      # Clean up the gloss
      clean_gloss = clean_text(gloss)

      # Parse morph into a simple POS string
      pos = parse_pos(morph)

      # Find or create the canonical lemma for this Strong's number
      canonical = find_or_create_canonical_lemma(
        language: language,
        headword: headword,
        norm_strongs: norm_strongs,
        transliteration: translit.presence,
        gloss: clean_gloss,
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
                                        gloss:, pos:, d_strong:, u_strong:)
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

      # Find lemmas currently linked to this Strong's via words. SCOPE BY
      # LANGUAGE: without this, "G154" matches Hebrew words whose bare
      # Strong's "154" coincides, and StepLexicon would smear Hebrew
      # metadata onto a Greek inflected-form lemma (the audit on
      # 2026-05-01 found 278 such cross-script contaminated rows). The
      # language guard makes that recurrence impossible.
      same_lang = case language
                  when "he", "arc"      then %w[he arc]
                  when "el", "el-koine" then %w[el el-koine grc]
                  else [language]
                  end
      linked_lemma_ids = Word.joins(:lemma)
                             .where(strongs_number: norm_strongs)
                             .where("lemmas.language IN (?)", same_lang)
                             .where.not(lemma_id: nil)
                             .distinct
                             .pluck(:lemma_id)

      canonical = nil

      if linked_lemma_ids.any?
        # Pick the best lemma among those linked to this Strong's number
        candidate = Lemma.where(id: linked_lemma_ids)
                         .select("lemmas.*, (SELECT COUNT(*) FROM words WHERE words.lemma_id = lemmas.id) AS wc")
                         .order(Arel.sql("CASE WHEN primary_gloss IS NOT NULL AND primary_gloss != '' THEN 0 ELSE 1 END, wc DESC"))
                         .first

        # Don't fold a multi-word place-name / compound headword into an
        # existing single-token lemma (or vice versa) just because they
        # share a base Strong's. TBESH ships H1004 (בַּיִת "house") and
        # H1004B (בֵּית הַיְשִׁימוֹת "Beth-jeshimoth") as separate rows
        # whose extended Strong's collapse to the same base. If we
        # accept the existing בַּיִת lemma here, line 239's
        # `canonical.lemma = headword` overwrites its text with
        # "Beth-jeshimoth" — silently relabeling 13k Word bindings.
        # Skip the reuse when token count differs; the create path
        # below will produce a distinct lemma row for this dictionary
        # entry, with zero Word bindings (correct — no corpus Word
        # uses the multi-word place compound as a single token).
        if candidate
          cand_tokens = candidate.lemma.to_s.strip.split(/\s+/).size
          new_tokens  = headword.to_s.strip.split(/\s+/).size
          canonical = candidate if cand_tokens == new_tokens
          bump(:lemmas_skipped_token_mismatch) if canonical.nil?
        end
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
      #
      # ALSO reject "(Place-of) X"-style place-modifier glosses entirely.
      # TBESH ships rows like `H5945E = יְהֹוִה` with gloss
      # "(Jerusalem of) the Lord" — these are place-modifier disambiguations,
      # not the dictionary sense, and they read terribly in the popover.
      # The bare-form sense ("YHWH/God") is what we want as primary_gloss.
      if gloss.present?
        existing_gloss = canonical.primary_gloss.to_s.strip
        new_is_proper      = gloss.match?(/\A[A-Z]/)
        new_is_paren       = gloss.match?(/\A\(/)
        existing_is_common = existing_gloss.present? && existing_gloss.match?(/\A[a-z]/)
        existing_is_paren  = existing_gloss.present? && existing_gloss.match?(/\A\(/)

        if existing_gloss.blank?
          canonical.primary_gloss = gloss
        elsif existing_is_paren && !new_is_paren
          # Existing is a place-modifier gloss; the new one is a real sense.
          # Overwrite — the place-modifier was never the right primary.
          canonical.primary_gloss = gloss
        elsif new_is_paren
          # Never overwrite or merge in a parenthetical place-modifier gloss.
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

      # Structured meanings are imported separately by
      # StepLexiconEntriesImporter as `lexicon_entries` rows. Don't write
      # to `lemmas.senses` from here — that path produced inconsistent
      # half-parsed strings that fought every regex cleanup.

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
      # Uniqueness violation — another lemma already has (language, lemma)
      # equal to what we tried to save canonical as. Find that row and
      # MERGE canonical into it: move canonical's words + lex entries
      # over, delete canonical, return the merged row.
      #
      # Critically: NFC-normalize the lookup. The model's before_validation
      # callback saved `headword` in NFC, but the raw `headword` passed
      # in may be NFD (TBESH source bytes). Without NFC normalization
      # the lookup misses and the merge silently turns into a row drop.
      nfc_headword = headword.unicode_normalize(:nfc)
      existing = Lemma.where(language: language, lemma: nfc_headword).first ||
                 Lemma.where(lemma: nfc_headword).where(language: [language, "he", "arc", "hbo"]).first ||
                 Lemma.where(lemma: nfc_headword).first
      unless existing
        $stdout.puts "[StepLexiconImporter] ERROR: #{headword} (#{norm_strongs}, #{language}): #{e.message}"
        $stdout.flush
        Rails.logger.warn "[StepLexiconImporter] skipping #{headword}: #{e.message}"
        bump(:lemmas_errored)
        return nil
      end

      merge_safety = check_merge_safety(canonical, existing, norm_strongs, language)
      case merge_safety
      when :safe
        # Move canonical's FKs to existing, then delete canonical.
        if canonical.persisted?
          Word.where(lemma_id: canonical.id).update_all(lemma_id: existing.id, updated_at: Time.current)
          LexiconEntry.where(lemma_id: canonical.id).update_all(lemma_id: existing.id, updated_at: Time.current)
          canonical.destroy
        end
        # Apply STEP metadata to the merged row.
        existing.transliteration ||= transliteration if transliteration.present?
        existing.part_of_speech  ||= pos             if pos.present?
        if gloss.present? && (existing.primary_gloss.blank? || existing.primary_gloss.match?(/\A[A-Z]/))
          existing.primary_gloss = gloss
        end
        existing.save!(validate: false) if existing.changed?
        bump(:lemmas_merged_on_collision)
        existing
      when :unsafe
        # canonical and existing are different lexemes that happen to
        # share a headword. Don't merge words. Update existing's metadata
        # opportunistically; canonical stays at whatever surface text
        # it had before this STEP row tried to rename it.
        if gloss.present? && (existing.primary_gloss.blank? || existing.primary_gloss.match?(/\A[A-Z]/))
          existing.update(primary_gloss: gloss, transliteration: transliteration || existing.transliteration)
        end
        bump(:lemmas_collision_kept_separate)
        existing
      end
    end

    # Decide whether merging `canonical` INTO `existing` would conflate
    # genuinely-distinct lexemes. Both must agree on their dominant
    # normalized Strong's number (or one side has no words at all, in
    # which case it's a stub safe to absorb).
    def check_merge_safety(canonical, existing, norm_strongs, language)
      can_top = canonical.persisted? ? top_norm_strongs(canonical.id, language) : norm_strongs
      ex_top  = top_norm_strongs(existing.id, existing.language)
      return :safe if can_top.nil? || ex_top.nil?
      return :safe if can_top == ex_top
      :unsafe
    end

    def top_norm_strongs(lemma_id, language)
      raw = Word.where(lemma_id: lemma_id).where.not(strongs_number: [nil, ""])
                .group(:strongs_number).order(Arel.sql("COUNT(*) DESC"))
                .limit(1).pick(:strongs_number)
      return nil unless raw
      Strongs.normalize(raw, language: language)
    end

    def cleanup_orphans
      # Remove lemmas that have zero words attached, no lexicon_entries
      # attached, and were NOT created by this importer. These are junk
      # surface-form placeholders left over from older importers that
      # are no longer the source of truth. Legitimate STEP-created
      # lemmas (lexicon entries for words not yet in the corpus) are
      # kept, as are any lemma row that has BDB / LSJ / STEPBible
      # entries pointing at it (the entries carry independent value).
      step_run_ids = ImportRun.where(importer_class: "Importers::StepLexiconImporter").pluck(:id)

      orphans = Lemma
        .where("NOT EXISTS (SELECT 1 FROM words WHERE words.lemma_id = lemmas.id)")
        .where("NOT EXISTS (SELECT 1 FROM lexicon_entries WHERE lexicon_entries.lemma_id = lemmas.id)")
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

  end
end
