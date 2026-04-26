require "test_helper"

class Search::Strategies::SemanticMergeTest < ActiveSupport::TestCase
  # Unit tests for the fusion logic in SemanticMerge#merge_results.
  # We stub out the encoder + vector DB so the test runs without a model
  # or pgvector data — the goal is to exercise RRF math, boost behavior,
  # dedup, and pinning, not the DB plumbing.

  def make_result(id, citation:, relevance:, body: nil, language: "en",
                  book_slug: "genesis", canonical_ref_id: nil, alias_match: false,
                  semantic: false)
    {
      id: id,
      work_slug: "test-en",
      work_title: "Test EN",
      language: language,
      canonical_ref_id: canonical_ref_id || id,  # default: separate verses
      citation: citation,
      hierarchy: [1, id],
      body: body || "verse #{id} body",
      headline: body || "verse #{id} body",
      relevance: relevance,
      license: "CC0",
      book_slug: book_slug,
      alias_match: alias_match,
      semantic: semantic,
    }
  end

  def make_merge(query, fts_results, semantic_results, **opts)
    fts_set = Search::ResultSet.new(
      results: fts_results, query: query, query_type: :text,
      total_count: fts_results.size
    )
    merge = Search::Strategies::SemanticMerge.new(query, fts_set, **opts)
    # Bypass encode_query + find_semantic_matches so we don't need
    # the model or the pgvector DB.
    merge.define_singleton_method(:encode_query) { [0.0] * 1024 }
    merge.define_singleton_method(:find_semantic_matches) { |_| semantic_results }
    merge
  end

  test "RRF: items in both lists outrank items in only one" do
    # Doc 1: rank 1 in FTS, rank 1 in semantic → wins
    # Doc 2: rank 2 in FTS only
    # Doc 3: rank 2 in semantic only
    fts = [
      make_result(1, citation: "Gen 1:1", relevance: 0.05),
      make_result(2, citation: "Gen 1:2", relevance: 0.03),
    ]
    sem = [
      make_result(1, citation: "Gen 1:1", relevance: 0.95, semantic: true),
      make_result(3, citation: "Gen 1:3", relevance: 0.85, semantic: true),
    ]
    result = make_merge("creation", fts, sem).call
    ids = result.results.map { |r| r[:id] }
    assert_equal 1, ids.first, "doc 1 (in both lists) should rank first"
  end

  test "alias_match in FTS triggers early-exit (no semantic dilution)" do
    # When FTS contains an alias match (from inject_alias_matches in
    # the executor, which runs before SemanticMerge), the merge bails out
    # and returns FTS results untouched. This protects high-confidence
    # passage-name lookups from being reordered by semantic similarity.
    fts = [
      make_result(1, citation: "Aaronic Blessing", relevance: 10.0, alias_match: true),
      make_result(2, citation: "Gen 1:2", relevance: 0.10),
    ]
    sem = [
      make_result(2, citation: "Gen 1:2", relevance: 0.95, semantic: true),
      make_result(3, citation: "Other", relevance: 0.85, semantic: true),
    ]
    result = make_merge("aaronic blessing", fts, sem).call
    assert result.results.first[:alias_match], "alias match should still be at top"
    assert_equal [1, 2], result.results.map { |r| r[:id] },
                 "early-exit should leave FTS list untouched (no dilution)"
  end

  test "RRF: phrase-bonus FTS hits (relevance > 5.0) pin via _orig_fts_relevance" do
    # When FTS phrase bonus fires, doc gets relevance > 5.0 in FTS only.
    # Even if semantic disagrees, pin to top.
    # NOTE: SemanticMerge has an early-exit when phrase_bonus_detected — to
    # exercise the pin code path we keep all FTS results within ~5x of each
    # other so the early-exit doesn't fire, then verify the pin still works.
    fts = [
      make_result(1, citation: "Matt 7:12", relevance: 6.0), # phrase-bonus boosted
      make_result(2, citation: "Matt 7:13", relevance: 4.5), # also strong (within 5x)
    ]
    sem = [
      make_result(2, citation: "Matt 7:13", relevance: 0.99, semantic: true),
      make_result(3, citation: "Luke 6:31", relevance: 0.95, semantic: true),
    ]
    result = make_merge("golden rule", fts, sem).call
    assert_equal 1, result.results.first[:id], "phrase-bonus FTS hit should pin to top"
  end

  test "RRF: skips when FTS detects strong phrase bonus" do
    # If the top FTS hit is 5x stronger than the bottom AND > 0.05, the merge
    # bails out and just returns the FTS result unchanged. This protects exact
    # phrase matches from being diluted by semantic noise.
    fts = [
      make_result(1, citation: "Matt 7:12", relevance: 1.0),  # phrase bonus
      make_result(2, citation: "Matt 7:13", relevance: 0.05), # ts_rank only
      make_result(3, citation: "Matt 7:14", relevance: 0.05),
    ]
    sem = [
      make_result(99, citation: "Other", relevance: 0.99, semantic: true),
    ]
    result = make_merge("golden rule", fts, sem).call
    assert_equal [1, 2, 3], result.results.map { |r| r[:id] },
                 "phrase-bonus detection should bypass semantic merge"
  end

  test "RRF strategy is the default" do
    assert_equal "rrf", Search::Strategies::SemanticMerge::FUSION_STRATEGY
  end

  test "RRF score is bounded — no _orig_fts_relevance leaks into result" do
    fts = [make_result(1, citation: "Gen 1:1", relevance: 0.05)]
    sem = [make_result(1, citation: "Gen 1:1", relevance: 0.95, semantic: true)]
    result = make_merge("creation", fts, sem).call
    refute result.results.first.key?(:_orig_fts_relevance),
           "internal _orig_fts_relevance must be stripped from output"
  end
end
