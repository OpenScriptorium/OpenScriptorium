require "test_helper"

class Api::V1::ManuscriptsControllerTest < ActionDispatch::IntegrationTest
  include CorpusSeedHelper

  setup do
    seed_test_corpus!
  end

  test "GET /api/v1/manuscripts lists manuscripts" do
    get api_v1_manuscripts_path
    assert_response :success
    json = JSON.parse(response.body)
    assert json["count"] >= 1
    assert json.key?("total_pages")
    ms = json["results"].find { |m| m["siglum"] == "𝔓1" }
    assert ms, "expected 𝔓1 in results"
    assert_equal "Papyrus 1", ms["name"]
  end

  test "GET /api/v1/manuscripts/:siglum" do
    get api_v1_manuscript_path(siglum: "𝔓1")
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "𝔓1", json["siglum"]
    assert_equal "Papyrus 1", json["name"]
  end

  test "GET /api/v1/manuscripts/:siglum returns 404 for unknown" do
    get api_v1_manuscript_path(siglum: "NOPE")
    assert_response :not_found
  end

  test "GET /api/v1/manuscripts with family filter" do
    get api_v1_manuscripts_path, params: { family: "alexandrian" }
    assert_response :success
    json = JSON.parse(response.body)
    # Our test manuscript has no family set, so it should be excluded
    assert_equal 0, json["count"]
  end
end
