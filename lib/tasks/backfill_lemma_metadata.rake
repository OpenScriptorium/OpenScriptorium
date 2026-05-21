namespace :lemmas do
  desc "Backfill missing lemma metadata (primary_gloss, transliteration) from linked LexiconEntry rows. Idempotent — only fills NULL/blank columns."
  task backfill_from_lexicon_entries: :environment do
    # Source preference for primary_gloss. STEPBible's brief lexicon is
    # already the source-of-truth for most lemmas (step_lexicon writes it
    # directly); we list it first so the same source is used for
    # consistency. BDB and LSJ fall in behind for lemmas STEP didn't cover.
    SOURCE_PRIORITY = %w[STEPBible BDB LSJ].freeze

    # Skip-list patterns: summary_gloss values that we already know read
    # badly as primary_gloss text. The parenthetical-prefix pattern is the
    # same one we just cleaned up in lemmas:fix_parenthetical_glosses.
    bad_gloss = ->(s) { s.blank? || s.start_with?("(") }

    puts "=== Backfilling primary_gloss ==="
    candidates = Lemma.where("primary_gloss IS NULL OR primary_gloss = ?", "")
    target = candidates.count
    puts "  lemmas missing primary_gloss: #{target}"

    filled = 0
    candidates.find_each do |l|
      # Pull all LexiconEntry rows for this lemma, ordered by preferred source.
      entries = LexiconEntry.where(lemma_id: l.id).to_a
      next if entries.empty?
      sorted = entries.sort_by { |e| SOURCE_PRIORITY.index(e.source) || 99 }

      chosen = sorted.find { |e| !bad_gloss.(e.summary_gloss.to_s.strip) }
      next unless chosen

      # Trim and normalize: drop trailing punctuation, collapse whitespace,
      # cap length so we don't blow out the popover.
      gloss = chosen.summary_gloss.to_s.gsub(/\s+/, " ").strip
      gloss = gloss[0, 200]
      l.update_columns(primary_gloss: gloss)
      filled += 1
    end
    puts "  filled: #{filled}"
    puts "  still missing (no usable LexEntry gloss): #{target - filled}"

    # Final fallback for primary_gloss: lemmas that still have no gloss
    # and no LexiconEntry but DO have Strong's-bearing Words. Pull the
    # common-word gloss directly from TBESH/TBESG keyed on the Word's
    # dominant Strong's. This covers inflected-form stubs whose
    # canonical dictionary lemma never got created (because the
    # importer hit a TBESH row with a letter-suffix and chose to skip).
    DIR = Rails.root.join("tmp/stepbible")
    tbe_gloss = {}
    [["TBESH.txt", "H"], ["TBESG.txt", "G"]].each do |fn, prefix|
      File.foreach(DIR.join(fn)) do |line|
        cols = line.split("\t")
        next if cols.size < 7
        ext = cols[0].to_s.strip
        next unless ext.start_with?(prefix)
        base = ext.match(/\A([HG])(\d+)/)&.then { |m| "#{m[1]}#{m[2].to_i}" }
        next unless base
        g = cols[6].to_s.strip
        next if g.empty? || g.start_with?("(")
        # Prefer common-word (lowercase) glosses if multiple are seen for
        # the same base Strong's, but fall back to a capitalized one for
        # proper nouns (e.g. "Babylon", "David") so the lemma still gets
        # *some* gloss instead of staying blank.
        existing = tbe_gloss[base]
        if existing.nil?
          tbe_gloss[base] = g
        elsif existing.match?(/\A[A-Z]/) && g.match?(/\A[a-z]/)
          tbe_gloss[base] = g
        end
      end
    end
    puts
    puts "  TBESH/TBESG fallback dictionary: #{tbe_gloss.size} entries"
    canonicalize = ->(raw, lang) {
      first = raw.to_s.split(",").first.to_s.strip
      m = first.match(/\A([HG])(\d+)/i)
      return "#{m[1].upcase}#{m[2].to_i}" if m
      return nil unless first.match?(/\A\d+\z/)
      prefix = %w[he arc hbo].include?(lang) ? "H" : "G"
      "#{prefix}#{first.to_i}"
    }
    fallback_filled = 0
    Lemma.where("primary_gloss IS NULL OR primary_gloss = ?", "").find_each do |l|
      raw = Word.where(lemma_id: l.id).where.not(strongs_number: [nil, ""])
                .group(:strongs_number).order(Arel.sql("COUNT(*) DESC"))
                .limit(1).pick(:strongs_number)
      next unless raw
      canon = canonicalize.(raw, l.language)
      g = canon && tbe_gloss[canon]
      next unless g
      l.update_columns(primary_gloss: g[0, 200])
      fallback_filled += 1
    end
    puts "  TBESH/TBESG fallback filled: #{fallback_filled}"

    puts
    puts "=== Backfilling transliteration ==="
    candidates = Lemma.where("transliteration IS NULL OR transliteration = ?", "")
                      .where(language: %w[he arc hbo el el-koine grc])
    target = candidates.count
    puts "  lemmas missing transliteration: #{target}"

    filled = 0
    candidates.find_each do |l|
      entries = LexiconEntry.where(lemma_id: l.id)
                            .where.not(transliteration: [nil, ""])
                            .to_a
      next if entries.empty?
      chosen = entries.sort_by { |e| SOURCE_PRIORITY.index(e.source) || 99 }.first
      t = chosen.transliteration.to_s.strip
      next if t.empty?
      l.update_columns(transliteration: t)
      filled += 1
    end
    puts "  filled: #{filled}"

    # Same TBESH/TBESG fallback as for primary_gloss — column 5 holds the
    # transliteration. We rebuild a tiny secondary index here to keep
    # the fallback dictionaries narrow.
    tbe_translit = {}
    [["TBESH.txt", "H"], ["TBESG.txt", "G"]].each do |fn, prefix|
      File.foreach(DIR.join(fn)) do |line|
        cols = line.split("\t")
        next if cols.size < 5
        ext = cols[0].to_s.strip
        next unless ext.start_with?(prefix)
        base = ext.match(/\A([HG])(\d+)/)&.then { |m| "#{m[1]}#{m[2].to_i}" }
        next unless base
        t = cols[4].to_s.strip
        next if t.empty?
        tbe_translit[base] ||= t
      end
    end
    fallback_filled = 0
    Lemma.where("transliteration IS NULL OR transliteration = ?", "").find_each do |l|
      raw = Word.where(lemma_id: l.id).where.not(strongs_number: [nil, ""])
                .group(:strongs_number).order(Arel.sql("COUNT(*) DESC"))
                .limit(1).pick(:strongs_number)
      next unless raw
      canon = canonicalize.(raw, l.language)
      t = canon && tbe_translit[canon]
      next unless t
      l.update_columns(transliteration: t)
      fallback_filled += 1
    end
    puts "  TBESH/TBESG fallback filled: #{fallback_filled}"
    puts "  still missing: #{Lemma.where('transliteration IS NULL OR transliteration = ?', '').where(language: %w[he arc hbo el el-koine grc]).count}"
  end
end
