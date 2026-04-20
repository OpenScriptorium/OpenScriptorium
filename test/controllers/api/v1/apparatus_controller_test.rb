require "test_helper"

class Api::V1::ApparatusControllerTest < ActionDispatch::IntegrationTest
  include CorpusSeedHelper

  setup do
    seed_test_corpus!
  end

  test "GET /api/v1/apparatus for a verse with variants" do
    get api_v1_apparatus_path, params: { book: "genesis", chapter: 1, verse: 1 }
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "genesis", json["source"]["book"]
    assert_equal 1, json["source"]["chapter"]
    assert_equal 1, json["source"]["verse"]
    assert json["variant_units"].length >= 1

    vu = json["variant_units"].first
    assert_equal "substitution", vu["variant_type"]
    assert_equal "ἐποίησεν", vu["lemma_text"]
    assert vu["readings"].length >= 2

    base = vu["readings"].find { |r| r["is_base"] }
    assert base, "expected a base reading"
    assert_equal "ἐποίησεν", base["text"]
    assert base["witnesses"].any? { |w| w["siglum"] == "𝔓1" }
  end

  test "GET /api/v1/apparatus for whole chapter" do
    get api_v1_apparatus_path, params: { book: "genesis", chapter: 1 }
    assert_response :success
    json = JSON.parse(response.body)
    assert json["variant_units"].length >= 1
    refute json["source"].key?("verse")
  end

  test "GET /api/v1/apparatus for unknown book returns 404" do
    get api_v1_apparatus_path, params: { book: "nonexistent", chapter: 1 }
    assert_response :not_found
  end

  test "GET /api/v1/apparatus for chapter with no variants" do
    get api_v1_apparatus_path, params: { book: "genesis", chapter: 3, verse: 3 }
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal [], json["variant_units"]
  end
end
