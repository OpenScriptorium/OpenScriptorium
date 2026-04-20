require "test_helper"

class SearchControllerTest < ActionDispatch::IntegrationTest
  include CorpusSeedHelper

  setup do
    seed_test_corpus!
  end

  test "GET /search with no query renders empty state" do
    get search_path
    assert_response :success
    assert_select "input[name=q]"
  end

  test "GET /search with query returns results" do
    get search_path, params: { q: "beginning" }
    assert_response :success
  end

  test "GET /search with citation redirects" do
    get search_path, params: { q: "Gen 1:1" }
    assert_response :redirect
  end

  test "GET /search/advanced redirects to /search" do
    get search_advanced_path
    assert_response :redirect
    assert_redirected_to "/search"
  end

  test "GET /search/completions returns JSON" do
    get search_completions_path, params: { q: "gen" }
    assert_response :success
    json = JSON.parse(response.body)
    assert json.is_a?(Array)
  end

  test "GET /search with section filter works" do
    get search_path, params: { q: "beginning", section: ["ot"] }
    assert_response :success
  end

  test "API search returns JSON" do
    get api_v1_search_path, params: { q: "beginning" }
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "beginning", json["query"]
    assert json["count"] >= 0
  end

  test "API search requires query" do
    get api_v1_search_path
    assert_response :bad_request
  end
end
