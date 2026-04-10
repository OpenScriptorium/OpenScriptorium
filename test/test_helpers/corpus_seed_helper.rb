# Minimal corpus seed for integration tests. Creates just enough data
# to exercise every reader route and feature:
#
#   - 1 versification scheme (KJV)
#   - 1 license (Public Domain)
#   - 1 canonical_work (Genesis) with 3 chapters × 3 verses each
#   - 2 works: an English translation ("test-en") with notes + red-letter,
#     and a Greek original ("test-gk") with word data + apparatus
#   - Cross-references between Gen 1:1 and Gen 2:1
#   - Pericopes on Genesis
#
# Call `seed_test_corpus!` in your test setup.
module CorpusSeedHelper
  def seed_test_corpus!
    @scheme = VersificationScheme.find_or_create_by!(code: "KJV") do |vs|
      vs.display_name = "King James Version"
    end

    @license = License.find_or_create_by!(name: "Public Domain") do |l|
      l.spdx_id = "LicenseRef-PD"
      l.url = "https://creativecommons.org/publicdomain/mark/1.0/"
      l.attribution_required = false
    end

    @genesis = CanonicalWork.find_or_create_by!(slug: "genesis") do |cw|
      cw.title = "Genesis"
      cw.book_key = "genesis"
      cw.testament = "ot"
      cw.citation_format = "scripture"
      cw.sbl_abbreviation = "Gen"
      cw.versification_scheme = @scheme
    end

    # Create 3 chapters × 3 verses = 9 canonical_refs
    @crefs = {}
    ord = 0
    (1..3).each do |ch|
      (1..3).each do |v|
        ord += 1
        @crefs[[ch, v]] = CanonicalRef.find_or_create_by!(
          canonical_work: @genesis, hierarchy: [ch, v]
        ) do |cr|
          cr.ord = ord
          cr.display_label = "#{ch}:#{v}"
          cr.sbl_citation = "Gen #{ch}:#{v}"
        end
      end
    end

    # English translation with notes + red-letter
    @en_work = Work.find_or_create_by!(slug: "test-en") do |w|
      w.title = "Test English Bible"
      w.work_type = "scripture_translation"
      w.language = "en"
      w.traditions = ["χ-protestant"]
      w.genre = "translation"
      w.license = @license
      w.default_versification_scheme = @scheme
      w.has_word_data = false
      w.pericope_traditions = ["bsb_editorial"]
    end

    en_ord = 0
    (1..3).each do |ch|
      (1..3).each do |v|
        en_ord += 1
        wu = WorkUnit.find_or_create_by!(
          work: @en_work, canonical_ref: @crefs[[ch, v]]
        ) do |u|
          u.ord = en_ord
          u.label = "#{ch}:#{v}"
          u.canonical_alignment_type = "exact"
        end
        wu.update!(body: "In the beginning God created the heavens and the earth verse #{ch}:#{v}")

        # Red-letter on 1:1 (words 1-3)
        if ch == 1 && v == 1
          wu.update!(markup: { "red_letter_positions" => [1, 2, 3] })
        end

        # Note on 1:2
        if ch == 1 && v == 2
          WorkUnitNote.find_or_create_by!(
            work_unit: wu, position_in_unit: 0
          ) do |n|
            n.note_type = "translation"
            n.anchor_text = "beginning"
            n.body = "Heb. reshit"
          end
        end

        # Note without anchor on 2:1 (whole-verse highlight)
        if ch == 2 && v == 1
          WorkUnitNote.find_or_create_by!(
            work_unit: wu, position_in_unit: 0
          ) do |n|
            n.note_type = "explanation"
            n.body = "This verse summarizes the creation account."
          end
        end
      end
    end

    # Greek original with word data + apparatus
    @gk_work = Work.find_or_create_by!(slug: "test-gk") do |w|
      w.title = "Test Greek NT"
      w.work_type = "scripture_original"
      w.language = "el-koine"
      w.traditions = ["academic"]
      w.genre = "original"
      w.license = @license
      w.default_versification_scheme = @scheme
      w.has_word_data = true
    end

    gk_ord = 0
    (1..3).each do |ch|
      (1..3).each do |v|
        gk_ord += 1
        wu = WorkUnit.find_or_create_by!(
          work: @gk_work, canonical_ref: @crefs[[ch, v]]
        ) do |u|
          u.ord = gk_ord
          u.label = "#{ch}:#{v}"
          u.canonical_alignment_type = "exact"
        end
        wu.update!(body: "Ἐν ἀρχῇ ἐποίησεν ὁ θεὸς τὸν οὐρανὸν καὶ τὴν γῆν #{ch}:#{v}")
      end
    end

    # Cross-reference: Gen 1:1 → Gen 2:1
    CrossReference.find_or_create_by!(
      source_canonical_work: @genesis,
      target_canonical_work: @genesis,
      source_dataset: "test"
    ) do |xr|
      s = @crefs[[1, 1]]
      t = @crefs[[2, 1]]
      xr.source_range = (s.ord...s.ord + 1)
      xr.target_range = (t.ord...t.ord + 1)
      xr.relationship_type = "parallels"
      xr.confidence = 1.0
      xr.status = "approved"
    end

    # Pericope on Genesis 1
    Pericope.find_or_create_by!(
      canonical_work: @genesis,
      source_dataset: "bsb_editorial",
      name: "The Creation"
    ) do |p|
      p.canonical_range = (@crefs[[1, 1]].ord...@crefs[[1, 3]].ord + 1)
      p.pericope_type = "heading"
      p.tradition = "bsb_editorial"
      p.sequence_number = 1
    end

    # Apparatus on Greek 1:1
    vu = VariantUnit.find_or_create_by!(
      canonical_ref: @crefs[[1, 1]],
      position_within_ref: 1
    ) do |v|
      v.lemma_text = "ἐποίησεν"
      v.variant_type = "substitution"
    end

    base = Reading.find_or_create_by!(variant_unit: vu, text: "ἐποίησεν")
    alt = Reading.find_or_create_by!(variant_unit: vu, text: "ἐποίει")
    vu.update!(base_reading: base) unless vu.base_reading_id

    ms = Manuscript.find_or_create_by!(siglum: "𝔓1") do |m|
      m.name = "Papyrus 1"
      m.language = "grc"
    end

    ReadingWitness.find_or_create_by!(reading: base, manuscript: ms)
  end
end
