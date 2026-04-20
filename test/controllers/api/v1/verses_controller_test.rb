require "test_helper"

class Api::V1::VersesControllerTest < ActionDispatch::IntegrationTest
  include CorpusSeedHelper

  setup do
    seed_test_corpus!

    # Create word data on greek work's Gen 1:1
    wu = WorkUnit.joins(:canonical_ref)
                 .where(work: @gk_work, canonical_refs: { hierarchy: [1, 1] })
                 .first!

    @lemma = Lemma.find_or_create_by!(language: "grc", lemma: "ἀρχή") do |l|
      l.normalized = "αρχη"
      l.primary_gloss = "beginning"
      l.transliteration = "arche"
      l.part_of_speech = "noun"
      l.frequency = 55
    end

    Word.find_or_create_by!(work: @gk_work, work_unit: wu, position: 1) do |w|
      w.surface = "Ἐν"
      w.normalized = "εν"
      w.morph_code = "PREP"
    end
    Word.find_or_create_by!(work: @gk_work, work_unit: wu, position: 2) do |w|
      w.surface = "ἀρχῇ"
      w.normalized = "αρχη"
      w.lemma = @lemma
      w.strongs_number = "G746"
      w.morph_code = "N-DSF"
    end
  end

  test "GET chapter without words param" do
    get "/api/v1/works/test-gk/genesis/1"
    assert_response :success
    json = JSON.parse(response.body)
    verse = json["verses"].first
    refute verse.key?("words"), "words should not be included by default"
  end

  test "GET chapter with words=true includes word data" do
    get "/api/v1/works/test-gk/genesis/1", params: { words: "true" }
    assert_response :success
    json = JSON.parse(response.body)
    verse = json["verses"].first
    assert verse.key?("words"), "words should be included when requested"
    assert verse["words"].length >= 2

    word = verse["words"].find { |w| w["surface"] == "ἀρχῇ" }
    assert word, "expected ἀρχῇ in word list"
    assert_equal "G746", word["strongs_number"]
    assert_equal "N-DSF", word["morph_code"]
    assert word["lemma"], "expected lemma on word"
    assert_equal "ἀρχή", word["lemma"]["lemma"]
    assert_equal "beginning", word["lemma"]["gloss"]
  end

  test "GET single verse with words=true" do
    get "/api/v1/works/test-gk/genesis/1/1", params: { words: "true" }
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal 1, json["verses"].length
    assert json["verses"].first.key?("words")
  end

  test "GET verse without words param returns no word data" do
    get "/api/v1/works/test-en/genesis/1/1"
    assert_response :success
    json = JSON.parse(response.body)
    refute json["verses"].first.key?("words")
  end
end
