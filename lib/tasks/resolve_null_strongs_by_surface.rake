namespace :lemmas do
  desc "Resolve Word rows with NULL lemma_id AND NULL strongs_number by matching their surface (diacritic-stripped) against existing Greek lemmas. Targets patriarchal-1904 Greek 'punctuation-elided' tokens like κατ᾽ and the 64 untagged words on first import."
  task resolve_null_strongs_by_surface: :environment do
    strip_diacritics = ->(s) {
      s.unicode_normalize(:nfd).gsub(/[\p{Mn}]/, "").unicode_normalize(:nfc).downcase
    }

    # Build index: stripped surface → most-common lemma_id (Greek only).
    puts "Building Greek surface→lemma index..."
    idx = Hash.new { |h, k| h[k] = Hash.new(0) }
    Word.joins(:lemma).where("lemmas.language IN (?)", %w[el el-koine grc])
        .where.not(lemma_id: nil)
        .pluck(:surface, :lemma_id).each do |s, lid|
      idx[strip_diacritics.(s)][lid] += 1
    end
    puts "  index entries: #{idx.size}"

    # Apply to every Greek-work Word with null lemma + null strongs.
    targets = Word.joins("JOIN work_units wu ON wu.id = words.work_unit_id JOIN works w ON w.id = wu.work_id")
                  .where(lemma_id: nil, strongs_number: nil)
                  .where("w.language IN (?)", %w[el el-koine grc])
    puts "Greek Words with null/null: #{targets.count}"

    resolved = 0
    unresolved = []
    targets.each do |w|
      candidates = idx[strip_diacritics.(w.surface)]
      if candidates.empty?
        unresolved << w
        next
      end
      best_lid = candidates.max_by { |_, n| n }.first
      strongs = Word.where(lemma_id: best_lid)
                    .where.not(strongs_number: [nil, ""])
                    .group(:strongs_number).order(Arel.sql("COUNT(*) DESC"))
                    .limit(1).pick(:strongs_number)
      w.update_columns(lemma_id: best_lid, strongs_number: strongs)
      resolved += 1
    end
    puts "Resolved by surface match: #{resolved}"
    puts "Unresolved:                #{unresolved.size}"

    # Hand-bind the common κατ᾽ → κατά case if it's still floating around.
    kata = Lemma.where(language: %w[el el-koine grc], lemma: "κατά").first
    if kata
      stragglers = unresolved.select { |w| w.surface.to_s.start_with?("κατ") && w.surface.to_s.length <= 5 }
      if stragglers.any?
        strongs = Word.where(lemma_id: kata.id).where.not(strongs_number: [nil, ""])
                      .group(:strongs_number).order(Arel.sql("COUNT(*) DESC")).limit(1).pick(:strongs_number)
        stragglers.each { |w| w.update_columns(lemma_id: kata.id, strongs_number: strongs) }
        puts "Hand-bound #{stragglers.size} κατ-prefixed elided tokens to κατά"
      end
    end
  end
end
