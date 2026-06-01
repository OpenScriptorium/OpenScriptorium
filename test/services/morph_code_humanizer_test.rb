require "test_helper"

class MorphCodeHumanizerTest < ActiveSupport::TestCase
  # --- existing formats (regression coverage) -----------------------------

  test "SBLGNT verb dashed" do
    assert_equal "Verb, Aorist Active Indicative 3rd Singular",
      MorphCodeHumanizer.humanize("V-AAI-3S")
  end

  test "SBLGNT noun dashed" do
    assert_equal "Noun, Nominative Singular Feminine",
      MorphCodeHumanizer.humanize("N-NSF")
  end

  test "CNTR positional verb" do
    assert_equal "Verb, Present Active Indicative 3rd person Singular",
      MorphCodeHumanizer.humanize("V:PAI3S..")
  end

  # --- lxx-morph format ---------------------------------------------------

  test "lxx single-word POS" do
    assert_equal "Conjunction",  MorphCodeHumanizer.humanize("conjunction")
    assert_equal "Preposition",  MorphCodeHumanizer.humanize("preposition")
    assert_equal "Particle",     MorphCodeHumanizer.humanize("particle")
    assert_equal "Adverb",       MorphCodeHumanizer.humanize("adverb")
    assert_equal "Interjection", MorphCodeHumanizer.humanize("interjection")
  end

  test "lxx verb with mid/pass slash voice" do
    assert_equal "Verb, Aorist Indicative Middle/Passive 3rd Singular",
      MorphCodeHumanizer.humanize("verb aor ind mid/pass 3rd sg")
  end

  test "lxx verb participle infinitive" do
    assert_equal "Participle, Aorist Participle Active Feminine Accusative Singular",
      MorphCodeHumanizer.humanize("participle aor ptc act fem acc sg")
  end

  test "lxx article with slash gender" do
    assert_equal "Article, Masculine/Neuter Dative Singular",
      MorphCodeHumanizer.humanize("article masc/neut dat sg")
  end

  test "lxx noun" do
    assert_equal "Noun, Masculine Genitive Plural",
      MorphCodeHumanizer.humanize("noun masc gen pl")
  end

  test "lxx adjective with slash case" do
    assert_equal "Adjective, Feminine Nominative/Vocative Singular",
      MorphCodeHumanizer.humanize("adjective fem nom/voc sg")
  end

  test "lxx adjective triple slash case" do
    assert_equal "Adjective, Neuter Nominative/Vocative/Accusative Plural",
      MorphCodeHumanizer.humanize("adjective neut nom/voc/acc pl")
  end

  test "lxx pronoun with person" do
    assert_equal "Pronoun, 1st Accusative Singular",
      MorphCodeHumanizer.humanize("pronoun 1st acc sg")
  end

  test "lxx proper noun (two-word POS)" do
    assert_equal "Proper Noun, Masculine Genitive Singular",
      MorphCodeHumanizer.humanize("proper noun masc gen sg")
    assert_equal "Proper Noun",
      MorphCodeHumanizer.humanize("proper noun")
  end

  test "lxx adjective comparative" do
    assert_equal "Adjective, Dative Comparative Plural",
      MorphCodeHumanizer.humanize("adjective dat comp pl")
  end

  test "unknown tokens after a known POS are dropped silently" do
    # Keep the POS prefix even if a parsing piece is unknown — partial
    # information beats raw output.
    assert_equal "Verb, Aorist Indicative",
      MorphCodeHumanizer.humanize("verb aor ind unknownthing")
  end

  test "completely unknown input falls through to the raw code" do
    assert_equal "weirdcode",  MorphCodeHumanizer.humanize("weirdcode")
    assert_equal "fem acc pl", MorphCodeHumanizer.humanize("fem acc pl") # missing POS
  end

  test "blank input returns nil" do
    assert_nil MorphCodeHumanizer.humanize(nil)
    assert_nil MorphCodeHumanizer.humanize("")
  end
end
