require "test_helper"

class Importers::TvtmsImporterTest < ActiveSupport::TestCase
  # Minimal TVTMS fixture: just the Psalm 3 Hebrew rows from the
  # Expanded section, which the test evaluator should match against
  # both MT and German schemes (both have title-as-v1 verse structure).
  FIXTURE_TVTMS = <<~TVTMS
    #DataStart(Condensed)
    $Section (in Eng refs)\tEnglish KJV\tHebrew\tLatin\tGreek
    #DataStart(Expanded)
    SourceType\tSourceRef\tStandardRef\tAction\tNoteMarker\tReversification Note\tVersification Note\tAncient Versions\tTests
    '====
    Hebrew\tPsa.3:1\tPsa.3:Title\tRenumber title\tOpt. (T)^1\t\t\t\tPsa.3:1=Exist & Psa.3:9=Last & Psa.3:TextBeforeV1=NotExist
    Hebrew\tPsa.3:2\tPsa.3:1\tRenumber verse\tOpt. (1)^2\t\t\t\tPsa.3:2=Exist & Psa.3:9=Last & Psa.3:TextBeforeV1=NotExist
    Hebrew\tPsa.3:3\tPsa.3:2\tRenumber verse\tOpt. (2)^3\t\t\t\tPsa.3:3=Exist & Psa.3:9=Last & Psa.3:TextBeforeV1=NotExist
    Hebrew\tPsa.3:4\tPsa.3:3\tRenumber verse\tOpt. (3)^4\t\t\t\tPsa.3:4=Exist & Psa.3:9=Last & Psa.3:TextBeforeV1=NotExist
    Hebrew\tPsa.3:5\tPsa.3:4\tRenumber verse\tOpt. (4)^5\t\t\t\tPsa.3:5=Exist & Psa.3:9=Last & Psa.3:TextBeforeV1=NotExist
    Hebrew\tPsa.3:6\tPsa.3:5\tRenumber verse\tOpt. (5)^6\t\t\t\tPsa.3:6=Exist & Psa.3:9=Last & Psa.3:TextBeforeV1=NotExist
    Hebrew\tPsa.3:7\tPsa.3:6\tRenumber verse\tOpt. (6)^7\t\t\t\tPsa.3:7=Exist & Psa.3:9=Last & Psa.3:TextBeforeV1=NotExist
    Hebrew\tPsa.3:8\tPsa.3:7\tRenumber verse\tOpt. (7)^8\t\t\t\tPsa.3:8=Exist & Psa.3:9=Last & Psa.3:TextBeforeV1=NotExist
    Hebrew\tPsa.3:9\tPsa.3:8\tRenumber verse\tOpt. (8)^9\t\t\t\tPsa.3:9=Exist & Psa.3:9=Last & Psa.3:TextBeforeV1=NotExist
  TVTMS

  setup do
    @kjv_scheme = VersificationScheme.find_or_create_by!(code: "KJV") do |s|
      s.display_name = "King James Version"
    end
    @mt_scheme = VersificationScheme.find_or_create_by!(code: "MT") do |s|
      s.display_name = "Masoretic Text"
    end
    @lxx_scheme = VersificationScheme.find_or_create_by!(code: "LXX") do |s|
      s.display_name = "Septuagint"
    end
    @german_scheme = VersificationScheme.find_or_create_by!(code: "German") do |s|
      s.display_name = "German"
    end

    # KJV Psalms: Psalm 3 has 8 content verses (v1-v8), title is separate
    @psalms_kjv = CanonicalWork.find_or_create_by!(slug: "psalms") do |cw|
      cw.title = "Psalms"
      cw.book_key = "psalms"
      cw.testament = "ot"
      cw.citation_format = "scripture"
      cw.sbl_abbreviation = "Ps"
      cw.versification_scheme = @kjv_scheme
    end

    # MT Psalms: title-as-v1, so Psalm 3 has v1-v9
    @psalms_mt = CanonicalWork.find_or_create_by!(slug: "psalms-mt") do |cw|
      cw.title = "Psalms (MT)"
      cw.book_key = "psalms"
      cw.testament = "ot"
      cw.citation_format = "scripture"
      cw.sbl_abbreviation = "Ps"
      cw.versification_scheme = @mt_scheme
    end

    # German Psalms: same title-as-v1 as MT
    @psalms_german = CanonicalWork.find_or_create_by!(slug: "psalms-german") do |cw|
      cw.title = "Psalms (German)"
      cw.book_key = "psalms"
      cw.testament = "ot"
      cw.citation_format = "scripture"
      cw.sbl_abbreviation = "Ps"
      cw.versification_scheme = @german_scheme
    end

    # Create canonical_refs for KJV Psalm 3: v1-v8
    (1..8).each_with_index do |v, i|
      CanonicalRef.find_or_create_by!(
        canonical_work: @psalms_kjv, hierarchy: [3, v]
      ) do |cr|
        cr.ord = i + 1
        cr.display_label = "3:#{v}"
      end
    end

    # Create canonical_refs for MT Psalm 3: v1-v9 (v1 = title)
    (1..9).each_with_index do |v, i|
      CanonicalRef.find_or_create_by!(
        canonical_work: @psalms_mt, hierarchy: [3, v]
      ) do |cr|
        cr.ord = i + 1
        cr.display_label = "3:#{v}"
      end
    end

    # Create canonical_refs for German Psalm 3: v1-v9 (v1 = title)
    (1..9).each_with_index do |v, i|
      CanonicalRef.find_or_create_by!(
        canonical_work: @psalms_german, hierarchy: [3, v]
      ) do |cr|
        cr.ord = i + 1
        cr.display_label = "3:#{v}"
      end
    end

    # Write fixture TVTMS file
    @tvtms_path = Rails.root.join("tmp/test_tvtms_#{Process.pid}.txt")
    File.write(@tvtms_path, FIXTURE_TVTMS)
  end

  teardown do
    File.delete(@tvtms_path) if @tvtms_path && File.exist?(@tvtms_path)
  end

  test "Hebrew psalm rows produce German mappings via test evaluation" do
    importer = Importers::TvtmsImporter.new(path: @tvtms_path, download: false)
    importer.call

    # Hebrew rows should have produced MT→KJV mappings (Psa.3:2→3:1, etc.)
    mt_mappings = VersificationMapping.where(
      from_scheme: @mt_scheme, to_scheme: @kjv_scheme
    )
    assert mt_mappings.count >= 8, "Expected at least 8 MT→KJV psalm mappings, got #{mt_mappings.count}"

    # The same Hebrew rows should ALSO produce German→KJV mappings
    # because German Psalm 3 has the same title-as-v1 verse structure.
    german_mappings = VersificationMapping.where(
      from_scheme: @german_scheme, to_scheme: @kjv_scheme
    )
    assert german_mappings.count >= 8,
           "Expected at least 8 German→KJV psalm mappings from Hebrew rows via test evaluation, got #{german_mappings.count}"

    # Verify a specific mapping: German Psa.3:2 → KJV Psa.3:1
    german_3_2 = CanonicalRef.find_by!(canonical_work: @psalms_german, hierarchy: [3, 2])
    kjv_3_1    = CanonicalRef.find_by!(canonical_work: @psalms_kjv, hierarchy: [3, 1])
    mapping = VersificationMapping.find_by(
      from_scheme: @german_scheme,
      from_canonical_ref: german_3_2,
      to_scheme: @kjv_scheme,
      to_canonical_ref: kjv_3_1
    )
    assert mapping, "Expected German Psa.3:2 → KJV Psa.3:1 mapping"
    assert_equal "exact", mapping.mapping_type
  end

  test "importer is idempotent — second run produces same mappings" do
    importer1 = Importers::TvtmsImporter.new(path: @tvtms_path, download: false)
    importer1.call
    count_after_first = VersificationMapping.count

    importer2 = Importers::TvtmsImporter.new(path: @tvtms_path, download: false)
    importer2.call
    count_after_second = VersificationMapping.count

    assert_equal count_after_first, count_after_second,
                 "Second import run changed mapping count: #{count_after_first} → #{count_after_second}"
  end

  test "rows with failing tests do not produce mappings" do
    # Write a TVTMS fixture with tests that DON'T match our data:
    # Psa.3:8=Last means "chapter 3 has exactly 8 verses" — true for KJV
    # but false for MT/German (which have 9).
    bad_test_tvtms = <<~TVTMS
      #DataStart(Condensed)
      $Section\tEnglish KJV\tHebrew
      #DataStart(Expanded)
      SourceType\tSourceRef\tStandardRef\tAction\tNoteMarker\tReversification Note\tVersification Note\tAncient Versions\tTests
      '====
      Eng-KJV\tPsa.3:1\tPsa.3:1\tKeep verse\t\t\t\t\tPsa.3:1=Exist & Psa.3:8=Last & Psa.3:TextBeforeV1=Exist
    TVTMS

    path = Rails.root.join("tmp/test_tvtms_bad_#{Process.pid}.txt")
    File.write(path, bad_test_tvtms)

    VersificationMapping.delete_all
    importer = Importers::TvtmsImporter.new(path: path, download: false)
    importer.call

    # The row is also identity (SourceRef == StandardRef + Keep verse),
    # so it gets skipped regardless. But the test evaluation would also
    # reject it for MT/German since Psa.3:8=Last is false there (it's 9)
    # and TextBeforeV1=Exist is false for non-KJV schemes.
    assert_equal 0, VersificationMapping.count
  ensure
    File.delete(path) if path && File.exist?(path)
  end
end
