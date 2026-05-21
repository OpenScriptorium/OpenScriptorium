namespace :lemmas do
  desc "Backfill metadata for homonym sibling lemmas using their bound Words' specific Strong's number against TBESH/TBESG."
  task backfill_homonym_siblings: :environment do
    DIR = Rails.root.join("tmp/stepbible")
    # TBESH/TBESG keyed by base Strong's — preserve gloss + transliteration
    # + morph code for THIS specific Strong's (not the lemma's text).
    tbe = {}
    [["TBESH.txt", "H"], ["TBESG.txt", "G"]].each do |fn, prefix|
      File.foreach(DIR.join(fn)) do |line|
        cols = line.split("\t")
        next if cols.size < 7
        ext = cols[0].to_s.strip
        next unless ext.start_with?(prefix)
        base = ext.match(/\A([HG])(\d+)/)&.then { |m| "#{m[1]}#{m[2].to_i}" }
        next unless base
        tbe[base] ||= {
          gloss: cols[6].to_s.strip,
          translit: cols[4].to_s.strip,
          morph: cols[5].to_s.strip
        }
      end
    end

    pos_for = ->(morph) {
      seg = morph.split("|").map(&:strip).find { |s| s.match?(/\A[NVADCP]/i) } || morph.split("|").first.to_s.strip
      case seg.split(/[-:]/).first.to_s
      when /\AN/i then "noun"
      when /\AV/i then "verb"
      when /\AA/i then "adjective"
      when /\AD/i then "adverb"
      when /\AC/i then "conjunction"
      when /\AP/i then "preposition"
      else nil
      end
    }

    # Sibling lemmas are characterized by: no primary_gloss yet, bound
    # Words exist, and another lemma with the same headword text also
    # exists (the original they were split from).
    sibling_ids = ActiveRecord::Base.connection.exec_query(<<~SQL).map { |r| r["id"] }
      SELECT l1.id FROM lemmas l1
      WHERE (l1.primary_gloss IS NULL OR l1.primary_gloss = '')
        AND EXISTS (SELECT 1 FROM words w WHERE w.lemma_id = l1.id)
        AND EXISTS (SELECT 1 FROM lemmas l2 WHERE l2.id <> l1.id AND l2.language = l1.language AND l2.lemma = l1.lemma);
    SQL
    puts "Homonym sibling lemmas to backfill: #{sibling_ids.size}"

    filled = 0
    sibling_ids.each do |lid|
      l = Lemma.find(lid)
      raw = Word.where(lemma_id: lid).where.not(strongs_number: [nil, ""])
                .group(:strongs_number).order(Arel.sql("COUNT(*) DESC"))
                .limit(1).pick(:strongs_number)
      next unless raw
      m = raw.split(",").first.to_s.strip.match(/\A([HG]?)(\d+)/i)
      next unless m
      canon = if m[1].present?
                "#{m[1].upcase}#{m[2].to_i}"
              else
                (l.language.in?(%w[he arc hbo]) ? "H" : "G") + m[2].to_i.to_s
              end
      info = tbe[canon]
      next unless info

      attrs = {}
      attrs[:primary_gloss]   = info[:gloss][0, 200]  if l.primary_gloss.blank? && info[:gloss].present? && !info[:gloss].start_with?("(")
      attrs[:transliteration] = info[:translit]      if l.transliteration.blank? && info[:translit].present?
      pos = pos_for.(info[:morph])
      attrs[:part_of_speech] = pos if l.part_of_speech.blank? && pos
      next if attrs.empty?
      l.update_columns(attrs)
      filled += 1
    end
    puts "Filled metadata for #{filled} siblings"
    puts "  (each sibling = one homonym sense; gets the gloss for ITS specific Strong's)"
  end
end
