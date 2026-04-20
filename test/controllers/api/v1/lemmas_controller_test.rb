require "test_helper"

class Api::V1::LemmasControllerTest < ActionDispatch::IntegrationTest
  include CorpusSeedHelper

  setup do
    seed_test_corpus!

    # Create a lemma and word for lexicon testing
    @lemma = Lemma.find_or_create_by!(language: "grc", lemma: "ἀρχή") do |l|
      l.normalized = "αρχη"
      l.primary_gloss = "beginning; origin"
      l.transliteration = "arche"
      l.part_of_speech = "noun"
      l.frequency = 55
      l.senses = [{ "gloss" => "beginning", "part_of_speech" => "noun" }]
      l.frequency_by_book = { "Gen" => 3, "John" => 2 }
    end

    # Create a word linked to the lemma
    wu = WorkUnit.joins(:canonical_ref)
                 .where(work: @gk_work, canonical_refs: { hierarchy: [1, 1] })
                 .first!
    @word = Word.find_or_create_by!(
      work: @gk_work, work_unit: wu, position: 2
    ) do |w|
      w.surface = "ἀρχῇ"
      w.normalized = "αρχη"
      w.lemma = @lemma
      w.strongs_number = "G746"
      w.morph_code = "N-DSF"
    end
  end

  test "GET /api/v1/lemmas requires query" do
    get api_v1_lemmas_path
    assert_response :bad_request
  end

  test "GET /api/v1/lemmas searches by gloss" do
    get api_v1_lemmas_path, params: { q: "beginning" }
    assert_response :success
    json = JSON.parse(response.body)
    assert json["count"] >= 1
    result = json["results"].find { |r| r["id"] == @lemma.id }
    assert result, "expected lemma in results"
    assert_equal "ἀρχή", result["lemma"]
    assert_equal "beginning; origin", result["primary_gloss"]
  end

  test "GET /api/v1/lemmas searches by transliteration" do
    get api_v1_lemmas_path, params: { q: "arche" }
    assert_response :success
    json = JSON.parse(response.body)
    assert json["results"].any? { |r| r["transliteration"] == "arche" }
  end

  test "GET /api/v1/lemmas searches by Strong's number" do
    get api_v1_lemmas_path, params: { q: "G746" }
    assert_response :success
    json = JSON.parse(response.body)
    assert json["results"].any? { |r| r["id"] == @lemma.id }
  end

  test "GET /api/v1/lemmas with language filter" do
    get api_v1_lemmas_path, params: { q: "beginning", language: "he" }
    assert_response :success
    json = JSON.parse(response.body)
    # Our grc lemma should be excluded
    refute json["results"].any? { |r| r["id"] == @lemma.id }
  end

  test "GET /api/v1/lemmas pagination" do
    get api_v1_lemmas_path, params: { q: "beginning", limit: 1, page: 1 }
    assert_response :success
    json = JSON.parse(response.body)
    assert json.key?("total_pages")
    assert json.key?("page")
    assert_equal 1, json["page"]
  end

  test "GET /api/v1/lemmas/:id returns detail" do
    get api_v1_lemma_path(@lemma)
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal @lemma.id, json["id"]
    assert_equal "ἀρχή", json["lemma"]
    assert_equal "beginning; origin", json["primary_gloss"]
    assert json.key?("senses")
    assert json.key?("frequency_by_book")
    assert json.key?("etymology")
    assert json["strongs_numbers"].include?("G746")
  end

  test "GET /api/v1/lemmas/:id returns 404 for missing" do
    get api_v1_lemma_path(0)
    assert_response :not_found
  end

  test "GET /api/v1/lemmas/strong/:number resolves" do
    get api_v1_lemma_strong_path(number: "G746")
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "G746", json["strongs_number"]
    assert json["lemmas"].any? { |l| l["id"] == @lemma.id }
  end

  test "GET /api/v1/lemmas/strong/:number rejects invalid" do
    get api_v1_lemma_strong_path(number: "BOGUS")
    assert_response :bad_request
  end

  test "GET /api/v1/lemmas/strong/:number returns 404 for unknown" do
    get api_v1_lemma_strong_path(number: "G9999")
    assert_response :not_found
  end
end
