namespace :lemmas do
  desc "Bind WLC clitic-prefix preposition+suffix tokens (לוֹ, בוֹ, כְּ…) to their TBESH preposition lemma (H9001-H9006)"
  task bind_clitic_prepositions: :environment do
    # BSB tables stores Hebrew preposition+pronominal-suffix compounds
    # ("ל֖וֹ" lo "to him", "ב֖וֹ" bo "in him") as single Word rows but
    # with no Strong's number — the source data doesn't decompose them
    # for Strong's purposes, and our schema only holds one Strong's
    # per Word, so they ended up null/null. We bind them by the
    # *lexical* prefix consonant (lamed → "to/for", beth → "in/with",
    # etc.) which is the dictionary-headword morpheme. The suffix is
    # inflectional pronoun morphology already captured in the Word's
    # morph_code ("Prep | 3ms" etc.).

    # First Hebrew character → (TBESH Strong's, headword, gloss).
    CLITIC_MAP = {
      "ל" => ["H9005", "לְ", "to/for"],
      "ב" => ["H9003", "בְ", "in/on/with"],
      "כ" => ["H9004", "כְ", "like/as"],
      "מ" => ["H9006", "מְ", "from"],
      "ו" => ["H9001", "וְ", "and"],
      "ה" => ["H9008", "הֲ", "interrogative he"],   # also H9009 (article); interrogative is more common in unresolved tokens
      "ש" => ["H9007", "שֶׁ", "which/that"],
    }.freeze

    # Find or create the lemma row for each clitic. Use language "he"
    # (these forms also appear in Aramaic but the lemma is the same).
    lemma_for = {}
    CLITIC_MAP.each do |first_char, (strongs, headword, gloss)|
      l = Lemma.where(language: %w[he arc], lemma: headword).first
      l ||= Lemma.create!(language: "he", lemma: headword, normalized: headword,
                          primary_gloss: gloss, part_of_speech: "preposition", frequency: 0)
      lemma_for[first_char] = [l, strongs]
    end

    wlc = Work.find_by(slug: "wlc")
    abort "WLC work not found" unless wlc

    targets = Word.where(work_id: wlc.id, lemma_id: nil, strongs_number: nil)
    puts "Candidate null/null WLC Words: #{targets.count}"

    bound = Hash.new(0)
    unbindable = 0
    targets.pluck(:id, :surface).each_slice(2_000) do |chunk|
      chunk.each do |id, surface|
        first_char = surface.to_s[0]
        info = lemma_for[first_char]
        unless info
          unbindable += 1
          next
        end
        l, strongs = info
        Word.where(id: id).update_all(lemma_id: l.id, strongs_number: strongs, updated_at: Time.current)
        bound[first_char] += 1
      end
    end

    puts
    puts "Bound by clitic prefix:"
    CLITIC_MAP.each do |c, (strongs, hw, _)|
      puts "  #{c} → #{strongs} (#{hw}):  #{bound[c]}"
    end
    puts "  unbindable (no matching first char): #{unbindable}"
    puts
    puts "Remaining null/null WLC Words: #{Word.where(work_id: wlc.id, lemma_id: nil, strongs_number: nil).count}"
  end
end
