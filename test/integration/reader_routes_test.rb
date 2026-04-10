require "test_helper"

class ReaderRoutesTest < ActionDispatch::IntegrationTest
  include CorpusSeedHelper

  setup do
    seed_test_corpus!
  end

  # --- Home & static pages ---

  test "home page loads" do
    get root_path
    assert_response :success
    assert_select "h1"
  end

  test "works index loads" do
    get works_path
    assert_response :success
    assert_select "a", text: /Test English Bible/
  end

  # --- Work show page ---

  test "work show page lists books" do
    get work_path("test-en")
    assert_response :success
    assert_select "h1", text: /Test English Bible/
    assert_select "a", text: "Genesis"
  end

  # --- Reader: book ---

  test "reader book page lists chapters" do
    get reader_book_path("test-en", "genesis")
    assert_response :success
    assert_select "a", text: "1"
  end

  # --- Reader: chapter ---

  test "reader chapter page renders verses" do
    get reader_chapter_path("test-en", "genesis", 1)
    assert_response :success
    assert_match "beginning God created", response.body
  end

  test "chapter page shows pericope heading" do
    get reader_chapter_path("test-en", "genesis", 1)
    assert_response :success
    assert_match "The Creation", response.body
  end

  test "chapter page renders marginal notes" do
    get reader_chapter_path("test-en", "genesis", 1)
    assert_response :success
    assert_match "Heb. reshit", response.body
  end

  test "chapter page renders red-letter spans when work has data" do
    get reader_chapter_path("test-en", "genesis", 1)
    assert_response :success
    assert_match 'class="rl"', response.body
  end

  test "chapter page with no notes uses simple layout" do
    get reader_chapter_path("test-gk", "genesis", 1)
    assert_response :success
    assert_match "Ἐν ἀρχῇ", response.body
  end

  # --- Reader: verse ---

  test "reader verse permalink" do
    get reader_verse_path("test-en", "genesis", 1, 1)
    assert_response :success
    assert_match "beginning", response.body
    assert_match "heavens", response.body
  end

  # --- Reader: range ---

  test "reader verse range" do
    get reader_range_path("test-en", "genesis", 1, 1, 2)
    assert_response :success
    assert_match "1:1", response.body
    assert_match "1:2", response.body
  end

  # --- Parallel reader ---

  test "parallel reader loads with multiple works" do
    get parallel_chapter_path("genesis", 1, works: "test-en,test-gk")
    assert_response :success
    assert_match "Test English Bible", response.body
    assert_match "Test Greek NT", response.body
  end

  test "parallel reader loads single work" do
    get parallel_chapter_path("genesis", 1, works: "test-en")
    assert_response :success
  end

  test "parallel reader verse mode" do
    get parallel_verse_path("genesis", 1, 1, works: "test-en,test-gk")
    assert_response :success
  end

  # --- Apparatus (Greek work) ---
  # Apparatus only shows for works with slug nestle1904 or cntr-sr,
  # so test-gk won't render it. We test that it's correctly absent.

  test "apparatus not shown for non-apparatus works" do
    cookies[:apparatus] = "on"
    get reader_chapter_path("test-gk", "genesis", 1)
    assert_response :success
    assert_no_match(/verse-apparatus/, response.body)
  end

  # --- Cross-references ---

  test "cross-references shown when cookie set" do
    cookies[:xref_datasets] = "test"
    get reader_chapter_path("test-en", "genesis", 1)
    assert_response :success
    assert_match "2:1", response.body
  end

  # --- Whole-verse note highlight ---

  test "verse with no-anchor note wraps body in annot span" do
    get reader_chapter_path("test-en", "genesis", 2)
    assert_response :success
    assert_match 'annot-verse', response.body
  end

  # --- 404s ---

  test "nonexistent work returns 404" do
    get work_path("nonexistent")
    assert_response :not_found
  end

  test "nonexistent chapter returns 404" do
    get reader_chapter_path("test-en", "genesis", 99)
    assert_response :not_found
  end
end
