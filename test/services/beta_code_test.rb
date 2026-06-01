require "test_helper"

class BetaCodeTest < ActiveSupport::TestCase
  test "plain letters (no diacritics)" do
    assert_equal ["και", nil], BetaCode.decode("kai")
  end

  test "acute accent" do
    assert_equal ["καί", nil], BetaCode.decode("kai/")
  end

  test "rough breathing" do
    assert_equal ["ὁ", nil], BetaCode.decode("o(")
  end

  test "smooth breathing + acute" do
    assert_equal ["ἀρχή", nil], BetaCode.decode("a)rxh/")
  end

  test "iota subscript" do
    assert_equal ["σῴζω", nil], BetaCode.decode("sw/|zw")
  end

  test "grave accent" do
    assert_equal ["καὶ", nil], BetaCode.decode("kai\\")
  end

  test "circumflex" do
    assert_equal ["κρῖνω", nil], BetaCode.decode("kri=nw")
  end

  test "diaeresis" do
    assert_equal ["ϊς", nil], BetaCode.decode("i+s")
  end

  test "capital marker" do
    assert_equal ["Ἀ", nil], BetaCode.decode("*a)")
  end

  test "digamma" do
    assert_equal ["ϝ", nil], BetaCode.decode("v")
  end

  test "compound hyphen stripped" do
    assert_equal ["ἱεροπράκτωρ", nil], BetaCode.decode("i(ero-pra/ktwr")
  end

  test "final sigma" do
    assert_equal ["ἄγγελος", nil], BetaCode.decode("a)/ggelos")
  end

  test "homonym suffix extracted" do
    assert_equal ["λέγω", 2], BetaCode.decode("le/gw2")
    assert_equal ["καί",  4], BetaCode.decode("kai/4")
    assert_equal ["ὁ",    1], BetaCode.decode("o(1")
  end

  test "length marks _ and ^ are consumed silently" do
    # Beta length markers don't have NFC representation; drop them.
    assert_equal ["κρινω", nil], BetaCode.decode("kri_nw")
    assert_equal ["κρινω", nil], BetaCode.decode("kri^nw")
  end

  test "empty input" do
    assert_equal ["", nil], BetaCode.decode("")
    assert_equal ["", nil], BetaCode.decode(nil)
  end

  test "LXX morph spot-check vocabulary" do
    [
      ["gi/nomai",    "γίνομαι"],
      ["e)n",         "ἐν"],
      ["ku/rios",     "κύριος"],
      ["au)to/s",     "αὐτός"],
      ["basileu/s",   "βασιλεύς"],
      ["bdelu/ssomai","βδελύσσομαι"]
    ].each do |beta, expected|
      assert_equal [expected, nil], BetaCode.decode(beta), "Beta #{beta} should be #{expected}"
    end
  end
end
