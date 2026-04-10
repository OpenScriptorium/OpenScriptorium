require "test_helper"

class WorkTest < ActiveSupport::TestCase
  include CorpusSeedHelper

  setup do
    seed_test_corpus!
  end

  test "feature_flags returns NTS for work with notes" do
    assert_includes @en_work.feature_flags, "NTS"
  end

  test "feature_flags returns QUO for work with red-letter" do
    assert_includes @en_work.feature_flags, "QUO"
  end

  test "feature_flags returns PRC for work with pericope traditions" do
    assert_includes @en_work.feature_flags, "PRC"
  end

  test "has_apparatus? true only for specific slugs" do
    refute @en_work.has_apparatus?
    refute @gk_work.has_apparatus?  # slug is test-gk, not nestle1904/cntr-sr
  end

  test "work_type_label maps correctly" do
    assert_equal "Scripture translation", @en_work.work_type_label
    assert_equal "Source-language scripture", @gk_work.work_type_label
  end

  test "slug validation rejects invalid characters" do
    license = License.find_by!(name: "Public Domain")
    w = Work.new(slug: "BAD SLUG!", title: "Bad", work_type: "other", license: license)
    refute w.valid?
    assert w.errors[:slug].any?
  end
end
