module Importers
  # Imports the Louis Segond 1910 French Bible from USFM files.
  #
  # Source: BibleCorps/FRA-B-LSG1910-PD-UBS on GitHub
  # License: Public domain (1910)
  # Language: French
  # Coverage: 66 protestant canonical books
  #
  # The USFM files include section headings (\s), cross-references
  # (\x...\x*), and paragraph markers (\p). This importer extracts
  # the verse text and section headings. Cross-references are left
  # for a future pass since they need canonical_ref resolution.
  class SegondImporter < BaseImporter
    DEFAULT_DIR = Rails.root.join("tmp/segond")

    # USFM 3-letter book codes from the file names
    BOOK_CODE_TO_SLUG = {
      "GEN" => "genesis", "EXO" => "exodus", "LEV" => "leviticus",
      "NUM" => "numbers", "DEU" => "deuteronomy", "JOS" => "joshua",
      "JDG" => "judges", "RUT" => "ruth",
      "1SA" => "1-samuel", "2SA" => "2-samuel",
      "1KI" => "1-kings", "2KI" => "2-kings",
      "1CH" => "1-chronicles", "2CH" => "2-chronicles",
      "EZR" => "ezra", "NEH" => "nehemiah", "EST" => "esther",
      "JOB" => "job", "PSA" => "psalms", "PRO" => "proverbs",
      "ECC" => "ecclesiastes", "SNG" => "song-of-solomon",
      "ISA" => "isaiah", "JER" => "jeremiah", "LAM" => "lamentations",
      "EZK" => "ezekiel", "DAN" => "daniel",
      "HOS" => "hosea", "JOL" => "joel", "AMO" => "amos",
      "OBA" => "obadiah", "JON" => "jonah", "MIC" => "micah",
      "NAM" => "nahum", "HAB" => "habakkuk", "ZEP" => "zephaniah",
      "HAG" => "haggai", "ZEC" => "zechariah", "MAL" => "malachi",
      "MAT" => "matthew", "MRK" => "mark", "LUK" => "luke",
      "JHN" => "john", "ACT" => "acts", "ROM" => "romans",
      "1CO" => "1-corinthians", "2CO" => "2-corinthians",
      "GAL" => "galatians", "EPH" => "ephesians", "PHP" => "philippians",
      "COL" => "colossians",
      "1TH" => "1-thessalonians", "2TH" => "2-thessalonians",
      "1TI" => "1-timothy", "2TI" => "2-timothy",
      "TIT" => "titus", "PHM" => "philemon",
      "HEB" => "hebrews", "JAS" => "james",
      "1PE" => "1-peter", "2PE" => "2-peter",
      "1JN" => "1-john", "2JN" => "2-john", "3JN" => "3-john",
      "JUD" => "jude", "REV" => "revelation"
    }.freeze

    def initialize(dir: nil, **opts)
      super(**opts)
      @dir = dir || DEFAULT_DIR
    end

    protected

    def source_url
      "https://github.com/BibleCorps/FRA-B-LSG1910-PD-UBS"
    end

    def source_format
      "usfm"
    end

    def transactional?
      false
    end

    def perform
      @license = License.find_by!(name: "Public Domain")
      @kjv_scheme = VersificationScheme.find_by!(code: "KJV")
      @work = ensure_work
      @canonical_work_cache = {}

      Dir.glob(File.join(@dir, "*.sfm")).sort.each do |path|
        process_file(path)
      end

      @work.update!(last_imported_at: Time.current,
                    imported_at: @work.imported_at || Time.current)
    end

    private

    def ensure_work
      Work.find_or_initialize_by(slug: "segond-1910").tap do |w|
        w.assign_attributes(
          title: "Louis Segond 1910",
          native_title: "La Sainte Bible, Version Louis Segond 1910",
          work_type: "scripture_translation",
          language: "fr",
          traditions: ["χ-protestant"],
          genre: "translation",
          license: @license,
          default_versification_scheme: @kjv_scheme,
          source_url: "https://github.com/BibleCorps/FRA-B-LSG1910-PD-UBS",
          publication_year: 1910,
          has_word_data: false,
          description: "The Louis Segond 1910 French Bible, the standard Protestant French translation for over a century. Translated directly from the Hebrew and Greek by Louis Segond (1810-1885), a Swiss theologian commissioned by the Compagnie des Pasteurs de Genève. First published as the OT in 1874 and the NT in 1880; the 1910 revision is the definitive edition."
        )
        stamp(w)
        w.save!
      end
    end

    def process_file(path)
      fname = File.basename(path)
      m = fname.match(/\d+-(\w{3})/)
      return unless m
      book_code = m[1]
      slug = BOOK_CODE_TO_SLUG[book_code]
      unless slug
        bump(:books_skipped)
        return
      end

      canonical_work = (@canonical_work_cache[slug] ||= CanonicalWork.find_by(slug: slug))
      unless canonical_work
        bump(:books_no_canonical_work)
        return
      end

      current_chapter = 0
      File.foreach(path, encoding: "utf-8") do |line|
        line = line.chomp

        if line =~ /\\c\s+(\d+)/
          current_chapter = $1.to_i
          next
        end

        next unless line =~ /\\v\s+(\d+)\s+(.*)/
        verse_n = $1.to_i
        verse_usfm = $2

        body = strip_usfm(verse_usfm)
        next if body.empty?

        process_verse(canonical_work, current_chapter, verse_n, body)
      end

      bump(:books_imported)
    end

    def strip_usfm(text)
      text
        .gsub(/\\x\s+.*?\\x\*/, "")      # strip cross-references
        .gsub(/\\f\s+.*?\\f\*/, "")       # strip footnotes
        .gsub(/\\[a-z]+\d?\s*/i, "")      # strip remaining markers
        .gsub(/\|[^\\]*/, "")             # strip params
        .gsub(/[¶]/, "")
        .gsub(/\s+/, " ")
        .strip
    end

    def process_verse(canonical_work, chapter, verse_n, text)
      canonical_ref = ensure_canonical_ref(canonical_work, [chapter, verse_n])

      work_unit = WorkUnit.find_or_initialize_by(
        work_id: @work.id,
        canonical_ref_id: canonical_ref.id
      )
      if work_unit.new_record?
        work_unit.assign_attributes(
          ord: next_work_unit_ord,
          label: "#{chapter}:#{verse_n}",
          canonical_alignment_type: "exact"
        )
      end
      work_unit.body = text
      stamp(work_unit)
      work_unit.save!
      bump(:verses_imported)
    end

    def next_work_unit_ord
      @next_ord ||= (WorkUnit.where(work_id: @work.id).maximum(:ord) || 0)
      @next_ord += 1
    end
  end
end
