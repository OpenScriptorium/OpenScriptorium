require "test_helper"

class Search::ExecutorTest < ActiveSupport::TestCase
  include CorpusSeedHelper

  setup do
    seed_test_corpus!
  end

  test "text search returns results with highlights" do
    result = Search::Executor.new("beginning").call
    assert_equal :text, result.query_type
    assert result.total_count > 0
    assert result.results.any? { |r| r[:headline].include?("<mark>") }
  end

  test "text search respects work scope" do
    result = Search::Executor.new("beginning", scope: { work: "test-en" }).call
    assert result.results.all? { |r| r[:work_slug] == "test-en" }
  end

  test "citation redirects to reader path" do
    result = Search::Executor.new("Gen 1:1").call
    assert result.redirect?, "Expected citation redirect"
    assert_match %r{/[^/]+/genesis/1/1}, result.redirect
  end

  test "citation with chapter only" do
    result = Search::Executor.new("Gen 1").call
    assert result.redirect?
    assert_match %r{/[^/]+/genesis/1\z}, result.redirect
  end

  test "blank query returns empty result" do
    result = Search::Executor.new("").call
    assert_equal :text, result.query_type
    assert result.empty?
  end

  test "result set has facets" do
    result = Search::Executor.new("beginning").call
    assert result.facets[:works].is_a?(Array)
    assert result.facets[:languages].is_a?(Array)
  end

  test "pagination works" do
    result = Search::Executor.new("beginning", per_page: 2, page: 1).call
    assert result.results.size <= 2
    assert result.total_pages >= 1
  end

  test "passage alias picks core verse not introductory verse in a range" do
    # Give verses distinctive text so FTS can differentiate them:
    #   Gen 1:1 → purely introductory (zero relevance to the alias keywords)
    #   Gen 1:2 → the actual blessing content
    #   Gen 1:3 → continuation
    en_wus = WorkUnit.joins(:work).where(works: { slug: "test-en" })
    wu1 = en_wus.joins(:canonical_ref)
                .where(canonical_refs: { sbl_citation: "Gen 1:1" }).first!
    wu2 = en_wus.joins(:canonical_ref)
                .where(canonical_refs: { sbl_citation: "Gen 1:2" }).first!
    wu3 = en_wus.joins(:canonical_ref)
                .where(canonical_refs: { sbl_citation: "Gen 1:3" }).first!
    # v1 has NO words matching the alias keywords — purely intro narration
    wu1.update!(body: "Then he spoke to his servants and said")
    wu2.update!(body: "The Lord bless you and keep you")
    wu3.update!(body: "The Lord make his face shine upon you")

    # Create a passage alias spanning Gen 1:1-3
    pa = PassageAlias.create!(ref: "Gen 1:1-3")
    PassageAliasName.create!(passage_alias: pa, name: "Priestly Blessing")
    PassageAliasName.create!(passage_alias: pa, name: "The Lord Bless You and Keep You")

    result = Search::Executor.new("Priestly Blessing").call
    alias_hit = result.results.find { |r| r[:alias_match] }

    assert alias_hit, "Expected a passage alias match in results"
    # Should pick Gen 1:2 ("The Lord bless you and keep you"),
    # NOT Gen 1:1 (purely introductory with no matching keywords)
    assert_equal "Gen 1:2", alias_hit[:citation],
      "Expected core verse Gen 1:2, got #{alias_hit[:citation]}"
  end

  test "passage alias falls back to first verse when no FTS signal" do
    # When alias names are academic terms that don't match any verse text,
    # we should still get the first verse rather than nothing.
    en_wus = WorkUnit.joins(:work).where(works: { slug: "test-en" })
    wu1 = en_wus.joins(:canonical_ref)
                .where(canonical_refs: { sbl_citation: "Gen 2:1" }).first!
    wu2 = en_wus.joins(:canonical_ref)
                .where(canonical_refs: { sbl_citation: "Gen 2:2" }).first!
    wu1.update!(body: "Thus the heavens and the earth were completed")
    wu2.update!(body: "And on the seventh day God rested")

    pa = PassageAlias.create!(ref: "Gen 2:1-2")
    PassageAliasName.create!(passage_alias: pa, name: "Hexaemeron Conclusion")

    result = Search::Executor.new("Hexaemeron Conclusion").call
    alias_hit = result.results.find { |r| r[:alias_match] }

    assert alias_hit, "Expected a passage alias match in results"
    # "Hexaemeron" doesn't appear in either verse, so fall back to first
    assert_equal "Gen 2:1", alias_hit[:citation]
  end

  test "passage alias for single-verse ref still works" do
    # Single-verse refs (no range) should work as before
    en_wu = WorkUnit.joins(:work, :canonical_ref)
                    .where(works: { slug: "test-en" })
                    .where(canonical_refs: { sbl_citation: "Gen 3:1" }).first!
    en_wu.update!(body: "Now the serpent was more crafty than any beast")

    pa = PassageAlias.create!(ref: "Gen 3:1")
    PassageAliasName.create!(passage_alias: pa, name: "The Serpent")

    result = Search::Executor.new("The Serpent").call
    alias_hit = result.results.find { |r| r[:alias_match] }

    assert alias_hit, "Expected a passage alias match in results"
    assert_equal "Gen 3:1", alias_hit[:citation]
  end
end
