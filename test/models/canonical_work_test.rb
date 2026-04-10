require "test_helper"

class CanonicalWorkTest < ActiveSupport::TestCase
  test "scripture citation format" do
    cw = CanonicalWork.new(
      slug: "test-gen", book_key: "test-gen", title: "Genesis",
      sbl_abbreviation: "Gen", citation_format: "scripture"
    )
    assert_equal "Gen 1:1", cw.format_citation([1, 1])
    assert_equal "Gen 1:1a", cw.format_citation([1, 1, 1])
    assert_equal "Gen 1:1b", cw.format_citation([1, 1, 2])
  end

  test "hierarchical citation format" do
    cw = CanonicalWork.new(
      slug: "test-ant", book_key: "test-ant", title: "Antiquities",
      sbl_abbreviation: "Ant.", citation_format: "hierarchical"
    )
    assert_equal "Ant. 1.1.1", cw.format_citation([1, 1, 1])
  end

  test "talmud citation format" do
    cw = CanonicalWork.new(
      slug: "test-ber", book_key: "test-ber", title: "Berakhot",
      sbl_abbreviation: "Ber.", citation_format: "talmud"
    )
    assert_equal "Ber. 2a", cw.format_citation([2, 1])
    assert_equal "Ber. 2b", cw.format_citation([2, 2])
    assert_equal "Ber. 2a:3", cw.format_citation([2, 1, 3])
  end

  test "display_title strips scheme parentheticals" do
    cw = CanonicalWork.new(title: "Psalms (MT)", slug: "psalms-mt", book_key: "psalms")
    assert_equal "Psalms", cw.display_title

    cw2 = CanonicalWork.new(title: "Psalms", slug: "psalms", book_key: "psalms")
    assert_equal "Psalms", cw2.display_title

    cw3 = CanonicalWork.new(title: "Berakhot (Bavli)", slug: "berakhot", book_key: "berakhot")
    assert_equal "Berakhot", cw3.display_title
  end

  test "testament validation allows rabbinic" do
    scheme = VersificationScheme.find_or_create_by!(code: "KJV") { |v| v.display_name = "KJV" }
    cw = CanonicalWork.new(
      slug: "test-rab", book_key: "test-rab", title: "Test",
      testament: "rabbinic", versification_scheme: scheme
    )
    assert cw.valid?, cw.errors.full_messages.join(", ")
  end
end
