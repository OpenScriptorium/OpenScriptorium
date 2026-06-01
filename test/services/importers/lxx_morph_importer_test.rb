require "test_helper"

class Importers::LxxMorphImporterTest < ActiveSupport::TestCase
  # Minimal LXX-morph fixture: one verse, three words, with the same
  # field shape the lxx-morph repo emits.
  FIXTURE = [
    {
      ref: "Ruth 1:1",
      words: [
        { surface: "καὶ",      lemma: "καί",    parsing: "",                       pos: "conjunction" },
        { surface: "ἐγένετο",  lemma: "γίνομαι", parsing: "aor ind mid/pass 3rd sg", pos: "verb" },
        { surface: "ἐν",       lemma: "ἐν",     parsing: "",                       pos: "preposition" }
      ]
    }
  ]

  setup do
    @license = License.find_or_create_by!(spdx_id: "CC0-1.0") do |l|
      l.name = "Public Domain"
      l.url  = "https://creativecommons.org/publicdomain/mark/1.0/"
    end

    @scheme = VersificationScheme.find_or_create_by!(code: "KJV") do |s|
      s.display_name = "King James Version"
    end

    @cw = CanonicalWork.find_or_create_by!(slug: "ruth") do |cw|
      cw.title                = "Ruth"
      cw.book_key             = "ruth"
      cw.testament            = "ot"
      cw.citation_format      = "scripture"
      cw.sbl_abbreviation     = "Ruth"
      cw.versification_scheme = @scheme
    end

    @ref = CanonicalRef.find_or_create_by!(canonical_work: @cw, hierarchy: [1, 1]) do |r|
      r.ord           = 1
      r.display_label = "1:1"
      r.sbl_citation  = "Ruth 1:1"
    end

    @work = Work.find_or_create_by!(slug: "rahlfs-lxx") do |w|
      w.title    = "Rahlfs Septuagint (1935)"
      w.license  = @license
      w.language = "el-koine"
      w.work_type = "scripture_original"
    end

    @wu = WorkUnit.find_or_create_by!(work: @work, canonical_ref: @ref) do |wu|
      wu.body = "καὶ ἐγένετο ἐν"
      wu.ord  = 1
    end

    @tmpdir = Dir.mktmpdir("lxx-morph-test")
    File.write(File.join(@tmpdir, "ruth.json"), JSON.generate(FIXTURE))
  end

  teardown do
    FileUtils.remove_entry(@tmpdir) if @tmpdir
  end

  test "imports words for a Rahlfs verse" do
    ENV["LXX_MORPH_PATH"] = @tmpdir
    Importers::LxxMorphImporter.new.call

    words = Word.where(work_unit_id: @wu.id).order(:position).to_a
    assert_equal 3, words.size
    assert_equal "καὶ", words[0].surface
    assert_equal "γίνομαι", words[1].lemma.lemma
    assert_equal "verb aor ind mid/pass 3rd sg", words[1].morph_code
    assert_nil words[2].morph_code.presence == nil ? words[2].morph_code : nil # ἐν → "preposition"
    assert_equal "preposition", words[2].morph_code
  ensure
    ENV.delete("LXX_MORPH_PATH")
  end

  test "is idempotent on re-run" do
    ENV["LXX_MORPH_PATH"] = @tmpdir
    Importers::LxxMorphImporter.new.call
    first_count = Word.where(work_unit_id: @wu.id).count
    word_updated_ats = Word.where(work_unit_id: @wu.id).pluck(:updated_at)

    stats = Importers::LxxMorphImporter.new.call
    assert_equal first_count, Word.where(work_unit_id: @wu.id).count
    assert_equal 3, stats[:words_unchanged]
    assert_equal 0, stats[:words_created].to_i
    assert_equal 0, stats[:words_updated].to_i

    # updated_at should be unchanged — no DB writes happened.
    assert_equal word_updated_ats, Word.where(work_unit_id: @wu.id).pluck(:updated_at)
  ensure
    ENV.delete("LXX_MORPH_PATH")
  end

  test "trims trailing rows when re-imported verse has fewer tokens" do
    ENV["LXX_MORPH_PATH"] = @tmpdir
    Importers::LxxMorphImporter.new.call
    assert_equal 3, Word.where(work_unit_id: @wu.id).count

    # Shorten the fixture to 1 word and re-import.
    shorter = [{ ref: "Ruth 1:1", words: [{ surface: "καὶ", lemma: "καί", parsing: "", pos: "conjunction" }] }]
    File.write(File.join(@tmpdir, "ruth.json"), JSON.generate(shorter))

    Importers::LxxMorphImporter.new.call
    assert_equal 1, Word.where(work_unit_id: @wu.id).count
  ensure
    ENV.delete("LXX_MORPH_PATH")
  end
end
