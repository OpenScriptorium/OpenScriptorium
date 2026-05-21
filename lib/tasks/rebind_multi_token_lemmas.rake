namespace :lemmas do
  desc "Rebind Words wrongly pointed at multi-token TBESH/TBESG lemma rows (Beth-jeshimoth, Zeus/Δίς, etc.) to the correct single-token canonical lemma via TBESG/TBESH Strong's→headword map."
  task rebind_multi_token: :environment do
    # =========================================================================
    # Why this exists
    # =========================================================================
    # StepLexiconImporter#find_or_create_canonical_lemma matches incoming
    # TBESH rows to existing lemmas by *base* Strong's number. TBESH ships
    # multiple rows for one base Strong's (suffix-letter homonyms: H1004,
    # H1004A, H1004B…). When the importer hit a place-name row like
    # "בֵּית הַיְשִׁימוֹת" (Beth-jeshimoth, e-strong = H1004B; base = H1004),
    # it pulled the existing common-noun lemma בַּ֫יִת ("house") via the
    # 13k+ Words already bound to it and *renamed* it to the place name.
    # Net effect: ~204 Hebrew + 48 Greek lemma rows were left with
    # multi-word/multi-spelling headwords absorbing tens of thousands of
    # unrelated Word bindings.
    #
    # This task rebinds those Words to the correct single-token lemma,
    # creating one from STEPBible's brief-lexicon source if none exists.
    # Same shape as lemmas:relink_words; reuses its TBESG/TBESH parser.
    # =========================================================================

    # NOTE: GRK_FAMILY order matters for new-lemma creation language tagging.
    # NT/LXX Words are el-koine; modern Greek "el" is what existing
    # lemma rows historically used in places. Put el-koine FIRST so newly
    # created targets get the right tag.
    HEB_FAMILY = %w[he arc hbo].freeze
    GRK_FAMILY = %w[el-koine el grc].freeze
    DIR = Rails.root.join("tmp/stepbible")

    unless File.exist?(DIR.join("TBESH.txt")) && File.exist?(DIR.join("TBESG.txt"))
      abort "TBESG/TBESH not found in #{DIR} — run import:step_lexicon first or stage the files"
    end

    # -------------------------------------------------------------------------
    # Step 1: Parse TBESG/TBESH into a Strong's → preferred-headword map.
    # Prefer SINGLE-TOKEN headwords (common nouns / verbs / single-word
    # proper names), but fall back to the file's multi-token headword
    # when no single-token form exists for that Strong's (compound place
    # names like Beth-shemesh and Greek idioms like ἵνα μή). The point
    # is to make sure EVERY Strong's gets ONE specific lemma row — what
    # StepLexicon collapsed onto a shared row.
    # -------------------------------------------------------------------------
    base_to_single_headword = {}   # "H1004" → "בַּיִת"
    base_to_multi_headword  = {}   # "H1053" → "בֵּית שֶׁ֫מֶשׁ"
    base_to_langs           = {}
    parse = ->(path, prefix, langs) {
      File.foreach(path) do |line|
        cols = line.split("\t")
        next if cols.size < 4
        ext = cols[0].to_s.strip
        next unless ext.start_with?(prefix)
        base = ext.match(/\A([HG])(\d+)/)&.then { |m| "#{m[1]}#{m[2].to_i}" }
        next unless base
        base_to_langs[base] ||= langs
        cols[3].to_s.split(",").map { |h| h.strip.unicode_normalize(:nfc) }.reject(&:empty?).each do |hw|
          if hw.include?(" ")
            base_to_multi_headword[base] ||= hw
          else
            base_to_single_headword[base] ||= hw
          end
        end
      end
    }
    parse.call(DIR.join("TBESH.txt"), "H", HEB_FAMILY)
    parse.call(DIR.join("TBESG.txt"), "G", GRK_FAMILY)
    puts "TBESG+TBESH single-token entries:  #{base_to_single_headword.size}"
    puts "TBESG+TBESH multi-token-only entries: #{(base_to_multi_headword.keys - base_to_single_headword.keys).size}"

    # -------------------------------------------------------------------------
    # Step 2: Find the suspect multi-token lemmas.
    # -------------------------------------------------------------------------
    # Multi-token detection: whitespace OR comma OR Hebrew maqaf (־,
    # the joiner used in compound names like אֲדֹנִי־צֶ֫דֶק "Adoni-zedek")
    # OR ASCII hyphen.
    multi_lemma_ids = ActiveRecord::Base.connection.exec_query(<<~SQL).map { |r| r["id"] }
      SELECT id FROM lemmas
      WHERE language IN ('he','arc','el','el-koine','grc')
        AND (lemma ~ '[[:space:]]' OR lemma ~ ',' OR lemma ~ '־' OR lemma ~ '-')
    SQL
    puts "Multi-token lemma rows to inspect: #{multi_lemma_ids.size}"

    # -------------------------------------------------------------------------
    # Step 3: For each Word bound to a multi-token lemma, rebind by its own
    # Strong's number. Create the target lemma if it doesn't exist yet.
    # -------------------------------------------------------------------------
    canonicalize_strongs = ->(raw, lang) {
      first = raw.to_s.split(",").first.to_s.strip
      m = first.match(/\A([HG])(\d+)/i)
      return "#{m[1].upcase}#{m[2].to_i}" if m
      return nil unless first.match?(/\A\d+\z/)
      prefix = HEB_FAMILY.include?(lang) ? "H" : "G"
      "#{prefix}#{first.to_i}"
    }

    target_lemma_cache = {}   # base_strongs → Lemma.id
    find_or_create_target = ->(base_strongs) {
      return target_lemma_cache[base_strongs] if target_lemma_cache.key?(base_strongs)
      headword = base_to_single_headword[base_strongs] || base_to_multi_headword[base_strongs]
      langs    = base_to_langs[base_strongs]
      unless headword && langs
        target_lemma_cache[base_strongs] = nil
        return nil
      end
      lang = langs.first
      # Look for an existing lemma with this exact headword first. If none,
      # create one keyed by THIS specific Strong's, even if another lemma
      # row already shares the multi-token headword text — Beth-shemesh
      # (H1053) and "Beth-shemesh"-the-Egyptian-Heliopolis are different
      # places, and each Strong's gets its own lemma.
      l = Lemma.where(language: langs, lemma: headword).first
      if l.nil?
        l = Lemma.create!(language: lang, lemma: headword, normalized: headword, frequency: 0)
      end
      target_lemma_cache[base_strongs] = l.id
      l.id
    }

    rebound      = 0
    no_target    = 0
    rebound_by_lemma = Hash.new(0)
    Word.where(lemma_id: multi_lemma_ids)
        .joins("JOIN lemmas ON lemmas.id = words.lemma_id")
        .pluck(:id, :strongs_number, :lemma_id, "lemmas.language")
        .each_slice(5_000) do |chunk|
      chunk.each do |word_id, raw_strong, lemma_id, lemma_lang|
        next if raw_strong.blank?
        base = canonicalize_strongs.(raw_strong, lemma_lang)
        next unless base
        target = find_or_create_target.(base)
        if target.nil?
          no_target += 1
          next
        end
        next if target == lemma_id  # already on the right one (rare)
        Word.where(id: word_id).update_all(lemma_id: target, updated_at: Time.current)
        rebound += 1
        rebound_by_lemma[lemma_id] += 1
      end
    end

    # -------------------------------------------------------------------------
    # Step 4: A second pass for SINGLE-TOKEN over-merges (lemmas where
    # Words with widely-separated Strong's share one lemma row — e.g.
    # מָ֫וֶת absorbing 15 Bamoth-place uses with H1120 alongside 568 real
    # death uses with H4194). For each such lemma, find the dominant
    # Strong's of the lemma; rebind every Word whose own Strong's
    # differs by > 20 from that dominant to its own canonical lemma.
    # -------------------------------------------------------------------------
    DELTA_THRESHOLD = 20
    second_pass_rebound = 0

    # Find candidate lemmas: ≥ 2 distinct canonicalized Strong's with
    # max - min > threshold.
    candidate_sql = <<~SQL
      WITH lemma_strongs AS (
        SELECT wd.lemma_id, l.language,
          CASE
            WHEN wd.strongs_number ~ '^[HG]\\d+' THEN
              regexp_replace(wd.strongs_number, '^([HG])0*(\\d+).*$', '\\1\\2')
            WHEN wd.strongs_number ~ '^\\d+$' AND l.language IN ('he','arc','hbo') THEN
              'H' || (wd.strongs_number::int)::text
            WHEN wd.strongs_number ~ '^\\d+$' AND l.language IN ('el','el-koine','grc') THEN
              'G' || (wd.strongs_number::int)::text
            ELSE NULL
          END AS canon
        FROM words wd JOIN lemmas l ON l.id = wd.lemma_id
        WHERE wd.strongs_number IS NOT NULL AND wd.strongs_number <> ''
          AND wd.strongs_number NOT LIKE '%,%'
      )
      SELECT lemma_id,
             MIN(SUBSTRING(canon FROM 2)::int) AS lo,
             MAX(SUBSTRING(canon FROM 2)::int) AS hi
      FROM lemma_strongs WHERE canon IS NOT NULL
      GROUP BY lemma_id HAVING COUNT(DISTINCT canon) >= 2 AND MAX(SUBSTRING(canon FROM 2)::int) - MIN(SUBSTRING(canon FROM 2)::int) > #{DELTA_THRESHOLD};
    SQL

    candidate_ids = ActiveRecord::Base.connection.exec_query(candidate_sql).map { |r| r["lemma_id"] }
    puts
    puts "Single-token over-merge candidates (Δ > #{DELTA_THRESHOLD}): #{candidate_ids.size}"

    candidate_ids.each do |lid|
      l = Lemma.find(lid)
      lang_family = HEB_FAMILY.include?(l.language) ? HEB_FAMILY : (GRK_FAMILY.include?(l.language) ? GRK_FAMILY : [l.language])

      # The lemma's dominant Strong's (the one whose Words make up the bulk).
      dom = ActiveRecord::Base.connection.exec_query(<<~SQL).first
        SELECT
          CASE
            WHEN strongs_number ~ '^[HG]\\d+' THEN regexp_replace(strongs_number, '^([HG])0*(\\d+).*$', '\\1\\2')
            ELSE '#{HEB_FAMILY.include?(l.language) ? "H" : "G"}' || (strongs_number::int)::text
          END AS canon,
          COUNT(*) AS n
        FROM words WHERE lemma_id = #{lid} AND strongs_number IS NOT NULL AND strongs_number <> ''
          AND strongs_number NOT LIKE '%,%' AND strongs_number ~ '^[HG0-9]'
        GROUP BY canon ORDER BY n DESC LIMIT 1;
      SQL
      next unless dom
      dom_num = dom["canon"].sub(/\A[HG]/, "").to_i

      # Rebind every Word whose canonicalized Strong's differs from dominant by > threshold.
      Word.where(lemma_id: lid)
          .where.not(strongs_number: [nil, ""])
          .where("strongs_number NOT LIKE '%,%' AND strongs_number ~ '^[HG0-9]'")
          .pluck(:id, :strongs_number).each do |wid, raw|
        canon = canonicalize_strongs.(raw, l.language)
        next unless canon
        num = canon.sub(/\A[HG]/, "").to_i
        next unless (num - dom_num).abs > DELTA_THRESHOLD
        target = find_or_create_target.(canon)
        next if target.nil? || target == lid
        Word.where(id: wid).update_all(lemma_id: target, updated_at: Time.current)
        second_pass_rebound += 1
      end
    end

    puts "Words rebound (single-token over-merge by Δ): #{second_pass_rebound}"

    # -------------------------------------------------------------------------
    # Step 5: Strict per-Word integrity check. For EVERY Word, the TBESH/TBESG
    # headword for its own Strong's must match (NFC) the text of the lemma
    # it's bound to. If not, rebind. This catches the residual cases the
    # Δ-distance heuristic missed — including #5711 שְׂאֵת absorbing 2,288
    # H5375 (נָשָׂא) Word uses, where lemma + Strong's disagree but neither
    # the multi-token nor the Δ filter caught it.
    # -------------------------------------------------------------------------
    third_pass_rebound = 0
    third_pass_skipped = 0

    # Index lemmas by (language family, NFC text) for fast lookup.
    lemma_by_text = {}
    Lemma.where(language: HEB_FAMILY + GRK_FAMILY).pluck(:id, :language, :lemma).each do |id, lang, text|
      next if text.nil?
      key = [HEB_FAMILY.include?(lang) ? :heb : :grk, text.unicode_normalize(:nfc)]
      lemma_by_text[key] ||= id
    end

    # Walk every Word in scripts we care about; check Strong's↔headword match.
    Word.joins("JOIN lemmas ON lemmas.id = words.lemma_id")
        .where("lemmas.language IN (?)", HEB_FAMILY + GRK_FAMILY)
        .where.not(strongs_number: [nil, ""])
        .where("words.strongs_number NOT LIKE '%,%'")
        .pluck("words.id", "words.strongs_number", "words.lemma_id", "lemmas.language", "lemmas.lemma")
        .each_slice(5_000) do |chunk|
      chunk.each do |wid, raw, lid, lang, current_text|
        canon = canonicalize_strongs.(raw, lang)
        next unless canon
        expected = base_to_single_headword[canon] || base_to_multi_headword[canon]
        next unless expected
        # Compare NFC. If they match, leave the Word alone.
        next if current_text && current_text.unicode_normalize(:nfc) == expected.unicode_normalize(:nfc)
        # Find or create a lemma whose text matches the expected headword.
        family_key = HEB_FAMILY.include?(lang) ? :heb : :grk
        target = lemma_by_text[[family_key, expected.unicode_normalize(:nfc)]]
        unless target
          fam = (family_key == :heb) ? HEB_FAMILY : GRK_FAMILY
          new_l = Lemma.create!(language: fam.first, lemma: expected, normalized: expected, frequency: 0)
          lemma_by_text[[family_key, expected.unicode_normalize(:nfc)]] = new_l.id
          target = new_l.id
        end
        if target == lid
          third_pass_skipped += 1
          next
        end
        Word.where(id: wid).update_all(lemma_id: target, updated_at: Time.current)
        third_pass_rebound += 1
      end
    end
    puts "Words rebound (Strong's↔headword integrity check): #{third_pass_rebound}"
    puts "  (no-op because target = source): #{third_pass_skipped}"

    puts
    puts "Words rebound (multi-token):    #{rebound}"
    puts "No target found:  #{no_target}"
    puts
    puts "Top sources (lemma_id → rebound-from count):"
    rebound_by_lemma.sort_by { |_, n| -n }.first(15).each do |lid, n|
      l = Lemma.find(lid)
      puts "  ##{lid.to_s.ljust(7)} #{l.lemma.inspect.ljust(36)} → #{n}"
    end
  end
end
