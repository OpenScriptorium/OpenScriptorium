namespace :lemmas do
  desc "Backfill lemmas.part_of_speech by extracting + normalizing morph_code from the lemma's bound Words. Idempotent — only fills NULL/blank columns."
  task backfill_part_of_speech: :environment do
    # Map the variety of morph-code conventions used across importers
    # (WLC: 'N-ms', Nestle1904: 'N-NMS', CNTR: 'N:......', RP: 'N-NSM',
    # WLC compound: 'Art | N-fs', etc.) down to a stable short POS token.
    classify_code = ->(code) {
      case code
      when /\A(noun|N)\z/i               then "noun"
      when /\AN-proper/i                 then "proper noun"
      when /\A(verb|V)\z/i               then "verb"
      when /\A(adj|adjective|A)\z/i      then "adjective"
      when /\A(adv|D)\z/i                then "adverb"
      when /\A(conj|C|CC)\z/i            then "conjunction"
      when /\A(prep|P)\z/i               then "preposition"
      when /\A(RA|Art)\z/i               then "article"
      when /\A(RP|Pro|Pron)\z/i          then "pronoun"
      when /\A(T|Prt|Particle|DirObjM)\z/i then "particle"
      when /\AInterj/i                   then "interjection"
      else nil
      end
    }

    pos_for = ->(morph) {
      return nil if morph.blank?
      # Iterate every pipe-separated segment and return the first POS we
      # recognize. The head-of-word in pipe-compound morphs varies:
      #   "Art | N-fs"      — head is the noun (LAST segment)
      #   "N-msc | 3ms"     — head is the noun (FIRST segment)
      #   "Conj-w | V-Qal…" — head is the verb (LAST segment)
      # Scanning every segment and taking the first recognizable POS
      # gets the right answer in all three patterns without needing
      # to disambiguate prefix vs suffix clitics.
      morph.split("|").each do |seg|
        seg = seg.to_s.strip
        # Strip CNTR-style colon-prefixed parsing and Nestle dash codes.
        code = seg.split(/[-:]/).first.to_s.strip
        # Match "N-proper-…" on the full segment so we can return
        # "proper noun" instead of plain "noun".
        return "proper noun" if seg.match?(/\AN-proper/i)
        pos = classify_code.(code)
        return pos if pos
      end
      nil
    }

    candidates = Lemma.where("part_of_speech IS NULL OR part_of_speech = ?", "")
    target = candidates.count
    puts "Lemmas missing part_of_speech: #{target}"

    filled = 0
    unknown_morphs = Hash.new(0)
    candidates.find_each do |l|
      # Most common morph code among Words bound to this lemma.
      top_morph = Word.where(lemma_id: l.id)
                     .where.not(morph_code: [nil, ""])
                     .group(:morph_code).order(Arel.sql("COUNT(*) DESC"))
                     .limit(1).pick(:morph_code)
      next unless top_morph
      pos = pos_for.(top_morph)
      if pos
        l.update_columns(part_of_speech: pos)
        filled += 1
      else
        unknown_morphs[top_morph] += 1
      end
    end

    puts "Filled from Word.morph_code: #{filled}"

    # Fallback: for lemmas whose Words have no morph_code (or didn't
    # match), pull POS from a linked LexiconEntry. STEPBible and BDB
    # carry usable POS codes; LSJ's "part_of_speech" is actually noun
    # inflection class, so we skip it.
    pos_from_le = ->(le) {
      raw = le.part_of_speech.to_s.strip
      return nil if raw.empty?
      case le.source
      when "STEPBible"
        # "G:V", "H:N-M", "G:N-F", "G:A", "N:N--L" etc.
        # Strip language prefix, take the first letter after ':'.
        code = raw.sub(/\A[GHN]:/, "").split("-").first.to_s
        case code
        when "N" then "noun"
        when "V" then "verb"
        when "A" then "adjective"
        when "P" then "preposition"
        when "C" then "conjunction"
        when "D" then "adverb"
        when "T" then "particle"
        end
      when "BDB"
        case raw
        when "N"  then "noun"
        when "Np" then "proper noun"
        when "V"  then "verb"
        when "A"  then "adjective"
        when "P"  then "preposition"
        when "C"  then "conjunction"
        when "D"  then "adverb"
        when "T"  then "particle"
        end
      else
        nil
      end
    }

    le_filled = 0
    Lemma.where("part_of_speech IS NULL OR part_of_speech = ''").find_each do |l|
      # Prefer STEPBible (most consistent), then BDB.
      le = LexiconEntry.where(lemma_id: l.id, source: "STEPBible").where.not(part_of_speech: nil).first
      le ||= LexiconEntry.where(lemma_id: l.id, source: "BDB").where.not(part_of_speech: nil).first
      next unless le
      pos = pos_from_le.(le)
      next unless pos
      l.update_columns(part_of_speech: pos)
      le_filled += 1
    end
    puts "Filled from LexiconEntry:    #{le_filled}"

    # Final fallback: pull POS directly from TBESG/TBESH source by the
    # lemma's bound Words' dominant Strong's. STEPBible's LexiconEntry
    # importer didn't populate part_of_speech for every entry, but the
    # raw TBESH/TBESG col 6 has the morph code for nearly all of them.
    DIR = Rails.root.join("tmp/stepbible")
    tbe_pos = {}
    [["TBESH.txt", "H"], ["TBESG.txt", "G"]].each do |fn, prefix|
      File.foreach(DIR.join(fn)) do |line|
        cols = line.split("\t")
        next if cols.size < 6
        ext = cols[0].to_s.strip
        next unless ext.start_with?(prefix)
        base = ext.match(/\A([HG])(\d+)/)&.then { |m| "#{m[1]}#{m[2].to_i}" }
        next unless base
        morph = cols[5].to_s.strip
        next if morph.empty?
        tbe_pos[base] ||= morph
      end
    end
    canonicalize = ->(raw, lang) {
      first = raw.to_s.split(",").first.to_s.strip
      m = first.match(/\A([HG])(\d+)/i)
      return "#{m[1].upcase}#{m[2].to_i}" if m
      return nil unless first.match?(/\A\d+\z/)
      prefix = %w[he arc hbo].include?(lang) ? "H" : "G"
      "#{prefix}#{first.to_i}"
    }
    tbe_filled = 0
    Lemma.where("part_of_speech IS NULL OR part_of_speech = ''").find_each do |l|
      raw = Word.where(lemma_id: l.id).where.not(strongs_number: [nil, ""])
                .group(:strongs_number).order(Arel.sql("COUNT(*) DESC"))
                .limit(1).pick(:strongs_number)
      # If no corpus uses, also try matching by any LE we have (some
      # lexicon-only lemmas have STEPBible LEs with the Strong's number
      # embedded in meta or headword path — out of scope here).
      next unless raw
      canon = canonicalize.(raw, l.language)
      morph = canon && tbe_pos[canon]
      next unless morph
      pos = pos_for.(morph)
      next unless pos
      l.update_columns(part_of_speech: pos)
      tbe_filled += 1
    end
    puts "Filled from TBESG/TBESH:     #{tbe_filled}"

    still_missing = Lemma.where("part_of_speech IS NULL OR part_of_speech = ''").count
    puts "Still missing: #{still_missing}"
    if unknown_morphs.any?
      puts
      puts "Top unrecognized morph patterns:"
      unknown_morphs.sort_by { |_, n| -n }.first(10).each { |m, n| puts "  #{m.inspect.ljust(40)} #{n}" }
    end
  end
end
