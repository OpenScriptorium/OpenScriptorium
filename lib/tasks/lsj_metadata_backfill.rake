namespace :lemmas do
  desc "Backfill POS + transliteration for LSJ-only Greek lemmas via lemma-ending classification + diacritic-strip transliteration"
  task lsj_metadata_backfill: :environment do
    # Greek POS by lemma ending. These suffix-patterns cover the regular
    # declensions and conjugations:
    #   -ω, -μι, -άω/έω/όω           → verb
    #   -ως (with σ at end of stem)  → adverb
    #   -ικός, -ινός, -ώς            → adjective
    #   -μα, -ος, -η, -α, -ον, -ις,
    #     -ων, -σις, -της, -ευς       → noun (broad bucket)
    pos_from_ending = ->(lemma) {
      l = lemma.unicode_normalize(:nfd).gsub(/[\p{Mn}]/, "").unicode_normalize(:nfc)
      return "verb"      if l =~ /(?:άω|έω|όω|ω|μι)\z/
      return "adverb"    if l =~ /(?:θεν|δον|χου)\z/
      return "adjective" if l =~ /(?:ικός|ινός|ώς|τός|νός)\z/
      return "noun"      if l =~ /(?:μα|σις|της|ευς|ων|ος|ης|ις|ευς|ων|η|α|ον|ξ|ψ|ρ|ν|ξις|σθος)\z/
      nil
    }

    # Greek → Latin transliteration. Lowercase, NFD-strip diacritics,
    # then map letter-by-letter. Polytonic accents/breathings (ϊ, ᾶ, ῷ)
    # get stripped down to base letter first.
    GREEK_TO_LATIN = {
      "α"=>"a","β"=>"b","γ"=>"g","δ"=>"d","ε"=>"e","ζ"=>"z","η"=>"ē","θ"=>"th",
      "ι"=>"i","κ"=>"k","λ"=>"l","μ"=>"m","ν"=>"n","ξ"=>"x","ο"=>"o","π"=>"p",
      "ρ"=>"r","σ"=>"s","ς"=>"s","τ"=>"t","υ"=>"u","φ"=>"ph","χ"=>"ch","ψ"=>"ps","ω"=>"ō"
    }.freeze
    transliterate = ->(text) {
      stripped = text.unicode_normalize(:nfd).gsub(/[\p{Mn}]/, "").downcase
      stripped.chars.map { |c| GREEK_TO_LATIN[c] || (c.match?(/[a-z]/) ? c : "") }.join
    }

    # ---- POS pass ----
    pos_target = Lemma.where("part_of_speech IS NULL OR part_of_speech = ''")
                      .where(language: %w[el el-koine grc])
    pos_initial = pos_target.count
    puts "Greek lemmas missing POS: #{pos_initial}"
    pos_filled = 0
    pos_target.find_each do |l|
      pos = pos_from_ending.(l.lemma)
      next unless pos
      l.update_columns(part_of_speech: pos)
      pos_filled += 1
    end
    puts "  filled via ending heuristic:           #{pos_filled}"
    puts "  still missing:                          #{pos_initial - pos_filled}"

    # ---- Transliteration pass ----
    tr_target = Lemma.where("transliteration IS NULL OR transliteration = ''")
                     .where(language: %w[el el-koine grc])
    tr_initial = tr_target.count
    puts
    puts "Greek lemmas missing transliteration: #{tr_initial}"
    tr_filled = 0
    tr_target.find_each do |l|
      t = transliterate.(l.lemma.to_s)
      next if t.empty?
      l.update_columns(transliteration: t)
      tr_filled += 1
    end
    puts "  filled via Greek→Latin mapping:        #{tr_filled}"
    puts "  still missing:                          #{tr_initial - tr_filled}"
  end
end
