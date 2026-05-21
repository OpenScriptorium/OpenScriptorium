namespace :lemmas do
  desc "Re-link Words with nil lemma_id via TBESG/TBESH Strong's→headword map. (Historical fix; phase 2's importer helper makes this obsolete in steady state.)"
  task relink_words: :environment do
    hebrew_family = %w[he arc hbo].freeze
    greek_family  = %w[el el-koine grc].freeze
    dir = Rails.root.join("tmp/stepbible")
    abort "TBESG/TBESH not found in #{dir}" unless File.exist?(dir.join("TBESG.txt"))

    # Parse a TBESG/TBESH row.
    # Columns:
    #   0: extended Strong's (G5216, G0001G, H0001A …)
    #   1: relationship phrase ("G5216 = a Form of", "G0001 = the Greek of")
    #   2: target Strong's (G4771, H0001 …)
    #   3: headword(s) of THIS row (comma-separated possibly)
    parse_rows = ->(path, prefix, langs) {
      rows = []
      File.foreach(path) do |line|
        cols = line.split("\t")
        next if cols.size < 4
        ext = cols[0].to_s.strip
        next unless ext.start_with?(prefix)
        rel = cols[1].to_s
        tgt = cols[2].to_s.strip
        headwords = cols[3].to_s.split(/[,]/).map { |h| h.strip.unicode_normalize(:nfc) }.reject(&:empty?)
        rows << { ext: ext, base: ext.match(/\A([HG])(\d+)/)&.then { |m| "#{m[1]}#{m[2].to_i}" },
                  rel: rel, tgt: tgt, headwords: headwords, langs: langs }
      end
      rows
    }
    rows = parse_rows.call(dir.join("TBESG.txt"), "G", greek_family) +
           parse_rows.call(dir.join("TBESH.txt"), "H", hebrew_family)
    puts "TBESG+TBESH rows parsed: #{rows.size}"

    # 1) Build a Strong's-form → lemma_id map. Try base Strong's, full
    #    extended ID, and zero-padded variants. Prefer first headword
    #    that matches a lemma in our DB.
    strong_to_lemma_id = {}
    headword_lemma_cache = {}  # (langs, headword) → lemma_id
    find_lemma = ->(langs, hw) {
      key = [langs, hw]
      headword_lemma_cache[key] ||= Lemma.where(language: langs, lemma: hw).pick(:id)
    }
    rows.each do |row|
      next if row[:base].nil?
      hw_match = row[:headwords].find { |hw| find_lemma.call(row[:langs], hw) }
      lid = hw_match ? find_lemma.call(row[:langs], hw_match) : nil
      strong_to_lemma_id[row[:base]] ||= lid if lid
      strong_to_lemma_id[row[:ext]]  ||= lid if lid
    end
    puts "Strong's → lemma map: #{strong_to_lemma_id.size}"

    # 2) Re-link Words with nil lemma_id, restricting to source-language-
    #    appropriate Strong's prefix.
    relinked = 0
    Word.where(lemma_id: nil).where.not(strongs_number: [nil, ""])
        .joins(:work)
        .pluck(:id, :strongs_number, "works.language")
        .group_by { |_, _, lang| lang }
        .each do |word_lang, slice|
      slice.each_slice(2000) do |chunk|
        chunk.each do |id, raw_strong, _|
          primary = raw_strong.split(",").first.to_s.strip
          # Determine prefix from work language; bare numerics get H if Hebrew, else G
          inferred_prefix = hebrew_family.include?(word_lang) ? "H" : "G"
          canon = if primary.match?(/\A[HG]\d/i)
                    primary[0].upcase + primary[1..].to_i.to_s
                  elsif primary.match?(/\A\d+\z/)
                    "#{inferred_prefix}#{primary.to_i}"
                  end
          next unless canon
          lid = strong_to_lemma_id[canon]
          # Try with the ext shape too (rare cases where TBESG only has "G0001G")
          unless lid
            full = primary.match?(/\A[HG]/i) ? primary.upcase : "#{inferred_prefix}#{primary}"
            lid = strong_to_lemma_id[full]
          end
          if lid
            Word.where(id: id).update_all(lemma_id: lid, updated_at: Time.current)
            relinked += 1
          end
        end
      end
    end
    puts "Words re-linked: #{relinked}"

    # NOTE: This task previously also wrote canonical_lemma_id bridges
    # from TBESG's "= a Form of" / "= a Name of" hints. That logic has
    # been removed: those hints describe linguistic relationships
    # (ἐμός↔ἐγώ, δούλη↔δοῦλος) NOT inflection chains, so bridging on
    # them merged distinct lemmas with different Strong's numbers and
    # phase 3 (lemmas:consolidate_inflected) would have catastrophically
    # collapsed unrelated word pools. Inflection coverage now comes
    # exclusively from importer-side Strong's lookups (find_lemma_by_strongs
    # in Importers::BaseImporter) which produce no bridges at all —
    # all words for the same Strong's bind to a single dictionary lemma.
  end
end
