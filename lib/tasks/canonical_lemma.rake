namespace :lemmas do
  desc "Backfill canonical_lemma_id by bridging via STEPBible's Strong's→headword map (TBESG / TBESH)"
  task backfill_canonical: :environment do
    require "csv"

    dir = Rails.root.join("tmp/stepbible")
    abort "TBESG/TBESH not found in #{dir}" unless File.exist?(dir.join("TBESG.txt"))

    # Hebrew family: he (Modern Hebrew code), arc (Aramaic), hbo (Biblical
    # Hebrew). Different importers wrote different language codes for the
    # same script + Strong's namespace, so canonical bridging must treat
    # them as one family or it'll route hbo lemmas through Greek by accident.
    hebrew_family = %w[he arc hbo].freeze
    greek_family  = %w[el el-koine grc].freeze

    strong_to_lemma_id = {}

    process = ->(path, lang_codes, prefix) {
      File.foreach(path) do |line|
        cols = line.split("\t")
        next if cols.size < 4
        base = cols[0].to_s.strip
        next unless base.start_with?(prefix)
        # Strip leading zeros from numeric portion: "G0001" → "G1"
        base_canonical = "#{prefix}#{base[1..].to_i}"
        next if strong_to_lemma_id.key?(base_canonical)

        headwords = cols[3].to_s.split(/[,]/).map { |h| h.strip.unicode_normalize(:nfc) }.reject(&:empty?)
        lemma = headwords.find do |hw|
          Lemma.where(language: lang_codes, lemma: hw).first
        end&.then { |hw| Lemma.where(language: lang_codes, lemma: hw).first }
        strong_to_lemma_id[base_canonical] = lemma.id if lemma
      end
    }

    process.call(dir.join("TBESG.txt"), greek_family,  "G")
    process.call(dir.join("TBESH.txt"), hebrew_family, "H")

    puts "Strong's → canonical lemma map size: #{strong_to_lemma_id.size}"

    # Iterate every lemma; for each, look at its Words' most-common
    # Strong's (canonicalized). If that Strong's maps to a different
    # canonical lemma in same language, point this lemma at it.
    updated = 0
    cleared = 0
    same = 0
    no_strong = 0
    no_canonical = 0

    Lemma.find_each do |l|
      strongs_count = Word.where(lemma_id: l.id)
                          .where.not(strongs_number: [nil, ""])
                          .group(:strongs_number)
                          .count
      if strongs_count.empty?
        # No words → can't bridge by Strong's. Skip but clear if currently set.
        if l.canonical_lemma_id.present?
          l.update_columns(canonical_lemma_id: nil, updated_at: Time.current)
          cleared += 1
        end
        no_strong += 1
        next
      end

      best_strong = strongs_count.max_by { |_, n| n }.first
      lang_for_prefix = hebrew_family.include?(l.language) ? "he" : "el-koine"
      canon = Strongs.normalize(best_strong, language: lang_for_prefix)
      unless canon
        prefix = hebrew_family.include?(l.language) ? "H" : "G"
        bare = best_strong.gsub(/\D/, "").to_i
        canon = bare.positive? ? "#{prefix}#{bare}" : nil
      end
      target = canon && strong_to_lemma_id[canon]

      if target.nil? || target == l.id
        target.nil? ? (no_canonical += 1) : (same += 1)
        if l.canonical_lemma_id.present?
          l.update_columns(canonical_lemma_id: nil, updated_at: Time.current)
          cleared += 1
        end
        next
      end

      # Cycle guard: target's canonical_lemma_id (if any) must not be l.id
      target_lemma = Lemma.find(target)
      if target_lemma.canonical_lemma_id == l.id
        no_canonical += 1
        next
      end

      next if l.canonical_lemma_id == target
      l.update_columns(canonical_lemma_id: target, updated_at: Time.current)
      updated += 1
    end

    puts "updated:      #{updated}"
    puts "cleared:      #{cleared}  (canonical_lemma_id -> nil where bridge no longer applies)"
    puts "self-links:   #{same}"
    puts "no Strong's:  #{no_strong}"
    puts "no canon map: #{no_canonical}"
  end
end
