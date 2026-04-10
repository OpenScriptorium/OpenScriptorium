module Importers
  # Imports the World English Bible British Edition with Deuterocanon.
  #
  # Source: eBible.org eng-webbe USFM
  # License: Public domain
  # Language: English (British spelling)
  # Coverage: 83 books — full Bible + deuterocanon
  # Features: footnotes (\f), red-letter (\wj), cross-references (\x)
  class WebbeImporter < BaseImporter
    DEFAULT_DIR = Rails.root.join("tmp/webbe")

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
      "GAL" => "galatians", "EPH" => "ephesians",
      "PHP" => "philippians", "COL" => "colossians",
      "1TH" => "1-thessalonians", "2TH" => "2-thessalonians",
      "1TI" => "1-timothy", "2TI" => "2-timothy",
      "TIT" => "titus", "PHM" => "philemon",
      "HEB" => "hebrews", "JAS" => "james",
      "1PE" => "1-peter", "2PE" => "2-peter",
      "1JN" => "1-john", "2JN" => "2-john", "3JN" => "3-john",
      "JUD" => "jude", "REV" => "revelation",
      # Deuterocanon
      "TOB" => "tobit", "JDT" => "judith",
      "ESG" => "esther-greek", "WIS" => "wisdom", "SIR" => "sirach",
      "BAR" => "baruch", "LJE" => "letter-of-jeremiah",
      "S3Y" => "prayer-of-azariah", "SUS" => "susanna",
      "BEL" => "bel-and-the-dragon",
      "1MA" => "1-maccabees", "2MA" => "2-maccabees",
      "1ES" => "1-esdras", "2ES" => "2-esdras",
      "MAN" => "prayer-of-manasseh",
      "PS2" => "psalm-151",
      "DAG" => "daniel"  # Greek additions to Daniel
    }.freeze

    def initialize(dir: nil, **opts)
      super(**opts)
      @dir = dir || DEFAULT_DIR
    end

    protected

    def source_url
      "https://ebible.org/find/details.php?id=eng-webbe"
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

      Dir.glob(File.join(@dir, "*.usfm")).sort.each do |path|
        process_file(path)
      end

      @work.update!(last_imported_at: Time.current,
                    imported_at: @work.imported_at || Time.current)
    end

    private

    def ensure_work
      Work.find_or_initialize_by(slug: "webbe").tap do |w|
        w.assign_attributes(
          title: "World English Bible British Edition",
          native_title: "World English Bible British Edition with Deuterocanon",
          work_type: "scripture_translation",
          language: "en",
          traditions: ["χ-protestant"],
          genre: "translation",
          license: @license,
          default_versification_scheme: @kjv_scheme,
          source_url: "https://ebible.org/find/details.php?id=eng-webbe",
          publication_year: 2023,
          has_word_data: false,
          description: "The World English Bible British Edition (WEBBE) with Deuterocanon. A modern English public domain translation using British spelling, based on the ASV with reference to the original languages. Includes the deuterocanonical/apocryphal books. Not copyrighted."
        )
        stamp(w)
        w.save!
      end
    end

    def process_file(path)
      fname = File.basename(path, ".usfm")
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
        current_chapter = $1.to_i if line =~ /\\c\s+(\d+)/
        next unless line =~ /\\v\s+(\d+)\s+(.*)/
        verse_n = $1.to_i
        verse_usfm = $2
        process_verse(canonical_work, current_chapter, verse_n, verse_usfm)
      end
      bump(:books_imported)
    end

    def strip_usfm(text)
      text
        .gsub(/\\f\s+.*?\\f\*/m, "")      # strip footnotes
        .gsub(/\\x\s+.*?\\x\*/m, "")      # strip cross-references
        .gsub(/\\wj\s*/i, "")             # strip red-letter open
        .gsub(/\\wj\*/i, "")              # strip red-letter close
        .gsub(/\\\+?w\s+([^|]+)\|[^\\]*\\\+?w\*/, '\1')  # strip \w word|...\w* and \+w word|...\+w*
        .gsub(/\\\+?[a-z]+\*?/i, "")      # strip remaining markers
        .gsub(/\|[^\\]*/,  "")             # strip params
        .gsub(/[¶]/, "")
        .gsub(/\s+/, " ")
        .strip
    end

    def process_verse(canonical_work, chapter, verse_n, usfm)
      canonical_ref = CanonicalRef.where(
        canonical_work_id: canonical_work.id,
        hierarchy: [chapter, verse_n]
      ).first
      unless canonical_ref
        bump(:verses_skipped)
        return
      end

      body = strip_usfm(usfm)
      return if body.empty?

      work_unit = WorkUnit.find_or_initialize_by(
        work_id: @work.id, canonical_ref_id: canonical_ref.id
      )
      if work_unit.new_record?
        work_unit.assign_attributes(
          ord: next_work_unit_ord,
          label: "#{chapter}:#{verse_n}",
          canonical_alignment_type: "exact"
        )
      end
      work_unit.body = body

      # Red-letter: extract word positions inside \wj...\wj*
      if usfm.include?("\\wj")
        rl_phrases = []
        usfm.scan(/\\wj\s+(.*?)\\wj\*/m) { |match| rl_phrases << strip_usfm(match[0]) }
        rl_phrases.reject!(&:empty?)
        if rl_phrases.any?
          positions = []
          search_from = 0
          rl_phrases.each do |phrase|
            pos = body.index(phrase, search_from)
            next unless pos
            prefix = body[0...pos]
            offset = prefix.split(/\s+/).reject(&:empty?).size
            phrase_words = phrase.split(/\s+/).size
            (1..phrase_words).each { |i| positions << (offset + i) }
            search_from = pos + phrase.length
          end
          markup = work_unit.markup || {}
          markup["red_letter_positions"] = positions.sort.uniq if positions.any?
          work_unit.markup = markup
        end
      end

      stamp(work_unit)
      work_unit.save!

      # Footnotes
      note_idx = 0
      usfm.scan(/\\f\s+\+\s+(.*?)\\f\*/m) do |match|
        fn_body = match[0]
          .gsub(/\\fr\s*[\d:.]+\s*/, "")
          .gsub(/\\ft\s*/, "")
          .gsub(/\\fqa?\s*/, "")
          .gsub(/\\\+?[a-z]+\*?\s*/i, "")
          .gsub(/\s+/, " ").strip
        next if fn_body.empty?
        WorkUnitNote.create!(
          work_unit: work_unit,
          position_in_unit: note_idx,
          note_type: fn_body =~ /\AOr,?\s/i ? "textual" : "explanation",
          body: fn_body,
          import_run_id: @import_run.id
        )
        note_idx += 1
        bump(:notes_created)
      end

      bump(:verses_imported)
    end

    def next_work_unit_ord
      @next_ord ||= (WorkUnit.where(work_id: @work.id).maximum(:ord) || 0)
      @next_ord += 1
    end
  end
end
