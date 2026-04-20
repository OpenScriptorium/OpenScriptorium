require "test_helper"

class Api::V1::SearchControllerTest < ActionDispatch::IntegrationTest
  include CorpusSeedHelper

  setup do
    seed_test_corpus!
  end

  test "GET /api/v1/search requires query" do
    get api_v1_search_path
    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_equal "query required", json["error"]
  end

  test "GET /api/v1/search returns results with pagination metadata" do
    get api_v1_search_path, params: { q: "beginning" }
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "beginning", json["query"]
    assert json.key?("count")
    assert json.key?("page")
    assert json.key?("per_page")
    assert json.key?("total_pages")
    assert json.key?("results")
  end

  test "GET /api/v1/search results include headline" do
    get api_v1_search_path, params: { q: "beginning" }
    assert_response :success
    json = JSON.parse(response.body)
    if json["results"].any?
      result = json["results"].first
      assert result.key?("headline"), "expected headline in results"
    end
  end

  test "GET /api/v1/search with section filter" do
    get api_v1_search_path, params: { q: "beginning", "section" => ["ot"] }
    assert_response :success
  end

  test "GET /api/v1/search with tradition filter" do
    get api_v1_search_path, params: { q: "beginning", "tradition" => ["academic"] }
    assert_response :success
  end

  test "GET /api/v1/search with work filter" do
    get api_v1_search_path, params: { q: "beginning", work: "test-en" }
    assert_response :success
  end

  test "GET /api/v1/search with book filter" do
    get api_v1_search_path, params: { q: "beginning", book: "genesis" }
    assert_response :success
  end

  test "GET /api/v1/search with language filter" do
    get api_v1_search_path, params: { q: "beginning", language: "en" }
    assert_response :success
  end

  test "GET /api/v1/search with work_types=all" do
    get api_v1_search_path, params: { q: "beginning", work_types: "all" }
    assert_response :success
  end

  test "GET /api/v1/search with pagination" do
    get api_v1_search_path, params: { q: "beginning", limit: 2, page: 1 }
    assert_response :success
    json = JSON.parse(response.body)
    assert json["per_page"] <= 2
  end

  test "GET /api/v1/search/completions returns suggestions" do
    get api_v1_search_completions_path, params: { q: "gen" }
    assert_response :success
    json = JSON.parse(response.body)
    assert json.is_a?(Array)
    book = json.find { |r| r["type"] == "book" }
    assert book, "expected a book suggestion for 'gen'"
    assert_includes book["label"].downcase, "genesis"
  end

  test "GET /api/v1/search/completions with short query returns empty" do
    get api_v1_search_completions_path, params: { q: "g" }
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal [], json
  end
end
