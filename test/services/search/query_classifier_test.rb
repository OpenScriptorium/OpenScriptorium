require "test_helper"

class Search::QueryClassifierTest < ActiveSupport::TestCase
  test "classifies Strong's numbers" do
    assert_equal :strongs, classify("H430").type
    assert_equal :strongs, classify("G3056").type
    assert_equal :strongs, classify("h1234").type
    assert_equal "H430",   classify("H430").query
  end

  test "classifies Hebrew script" do
    assert_equal :hebrew, classify("בראשית").type
    assert_equal :hebrew, classify("בְּרֵאשִׁית").type  # with nikud
  end

  test "classifies Greek script" do
    assert_equal :greek, classify("λόγος").type
    assert_equal :greek, classify("ἀρχή").type
  end

  test "classifies lemma: prefix" do
    result = classify("lemma:ברא")
    assert_equal :lemma, result.type
    assert_equal "ברא",  result.query
  end

  test "classifies morph: prefix" do
    result = classify("morph:V-AAI-*")
    assert_equal :morphological, result.type
    assert_equal "V-AAI-*",      result.query
  end

  test "classifies citations" do
    assert_equal :citation, classify("Gen 1:1").type
    assert_equal :citation, classify("1 Sam 3:16").type
    assert_equal :citation, classify("Ps 23").type
    assert_equal :citation, classify("Rev 21:1").type
  end

  test "classifies plain text as text" do
    assert_equal :text, classify("in the beginning").type
    assert_equal :text, classify("grace and mercy").type
  end

  test "classifies regex: prefix" do
    result = classify("regex:begat\\s\\w+")
    assert_equal :regex, result.type
    assert_equal 'begat\s\w+', result.query
  end

  test "classifies xref: prefix" do
    result = classify("xref:Gen 1:1")
    assert_equal :xref_traversal, result.type
    assert_equal "Gen 1:1", result.query
  end

  test "classifies apparatus" do
    assert_equal :apparatus, classify("apparatus").type
    result = classify("apparatus substitution")
    assert_equal :apparatus, result.type
    assert_equal "substitution", result.extra[:variant_type]
  end

  test "classifies proximity with NEAR" do
    result = classify("grace NEAR/5 mercy")
    assert_equal :proximity, result.type
    assert_equal "grace", result.extra[:term_a]
    assert_equal "mercy", result.extra[:term_b]
    assert_equal 5, result.extra[:distance]
  end

  test "classifies proximity with NEAR default distance" do
    result = classify("grace NEAR mercy")
    assert_equal :proximity, result.type
    assert_equal 5, result.extra[:distance]
  end

  test "blank query returns text type" do
    assert_equal :text, classify("").type
    assert_equal :text, classify("  ").type
  end

  private

  def classify(q)
    Search::QueryClassifier.classify(q)
  end
end
