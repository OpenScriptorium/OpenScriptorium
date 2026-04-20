require "open-uri"

module Importers
  # Imports the OpenBible.info cross-references dataset.
  #
  # Source: https://www.openbible.info/labs/cross-references/
  # Direct: https://a.openbible.info/data/cross-references.zip
  # License: CC BY 4.0
  # Volume: ~344,800 cross-references
  #
  # ## Format
  #
  # Tab-separated, with a header line. Three columns:
  #
  #   From Verse  To Verse              Votes
  #   Gen.1.1     Matt.11.25            13
  #   Gen.1.1     Col.1.16-Col.1.17     161
  #
  # The `From Verse` is always a single verse (USFM-style
  # `Book.chapter.verse`). The `To Verse` is either a single verse
  # or a range `Book.ch.v-Book.ch.v` which may cross chapters. Votes
  # is OpenBible's crowdsourced relevance score; we map it to
  # `confidence` on a 0..1 scale (capped — anything ≥ 100 votes is
  # confidence 1.0).
  #
  # ## Idempotency
  #
  # First run: wipes any existing rows tagged
  # `source_dataset = "openbible"` then bulk-inserts. The dataset is
  # deterministic — re-running on the same source produces zero diffs.
  class OpenbibleXrefsImporter < BaseImporter
    SOURCE_URL = "https://a.openbible.info/data/cross-references.zip"
    DEFAULT_DIR = Rails.root.join("tmp/openbible")
    SOURCE_DATASET = "openbible".freeze

    # USFM book code → canonical_works.book_key. Same shape as the
    # TvtmsImporter map but extended for OpenBible's variants
    # (`Phlm`, `Sng`, `Jud` for Jude, etc.).
    BOOK_CODE_TO_KEY = {
      "Gen"   => "genesis",     "Exod" => "exodus",     "Lev"  => "leviticus",
      "Num"   => "numbers",     "Deut" => "deuteronomy",
      "Josh"  => "joshua",      "Judg" => "judges",     "Ruth" => "ruth",
      "1Sam"  => "1-samuel",    "2Sam" => "2-samuel",
      "1Kgs"  => "1-kings",     "2Kgs" => "2-kings",
      "1Chr"  => "1-chronicles", "2Chr" => "2-chronicles",
      "Ezra"  => "ezra",        "Neh"  => "nehemiah",   "Esth" => "esther",
      "Job"   => "job",         "Ps"   => "psalms",     "Prov" => "proverbs",
      "Eccl"  => "ecclesiastes", "Song" => "song-of-solomon",
      "Isa"   => "isaiah",      "Jer"  => "jeremiah",   "Lam"  => "lamentations",
      "Ezek"  => "ezekiel",     "Dan"  => "daniel",
      "Hos"   => "hosea",       "Joel" => "joel",       "Amos" => "amos",
      "Obad"  => "obadiah",     "Jonah" => "jonah",     "Mic"  => "micah",
      "Nah"   => "nahum",       "Hab"  => "habakkuk",   "Zeph" => "zephaniah",
      "Hag"   => "haggai",      "Zech" => "zechariah",  "Mal"  => "malachi",
      "Matt"  => "matthew",     "Mark" => "mark",       "Luke" => "luke",
      "John"  => "john",        "Acts" => "acts",       "Rom"  => "romans",
      "1Cor"  => "1-corinthians", "2Cor" => "2-corinthians",
      "Gal"   => "galatians",   "Eph"  => "ephesians",  "Phil" => "philippians",
      "Col"   => "colossians",
      "1Thess" => "1-thessalonians", "2Thess" => "2-thessalonians",
      "1Tim"  => "1-timothy",   "2Tim" => "2-timothy",
      "Titus" => "titus",       "Phlm" => "philemon",
      "Heb"   => "hebrews",     "Jas"  => "james",
      "1Pet"  => "1-peter",     "2Pet" => "2-peter",
      "1John" => "1-john",      "2John" => "2-john",   "3John" => "3-john",
      "Jude"  => "jude",        "Rev"  => "revelation"
    }.freeze

    def initialize(dir: nil, download: nil, **opts)
      super(**opts)
      @dir = dir || DEFAULT_DIR
      @download = download.nil? ? !File.exist?(tsv_path) : download
    end

    protected

    def source_url
      SOURCE_URL
    end

    def source_format
      "tsv"
    end

    def transactional?
      false
    end

    def perform
      ensure_source_present!

      Rails.logger.info "[OpenbibleXrefsImporter] wiping existing rows"
      CrossReference.where(source_dataset: SOURCE_DATASET).delete_all

      @canonical_work_cache = {}
      @ref_cache = {}

      Rails.logger.info "[OpenbibleXrefsImporter] parsing #{tsv_path}"
      batch = []
      File.open(tsv_path, "r:bom|utf-8") do |f|
        f.each_line.with_index do |line, idx|
          next if idx == 0  # header
          line = line.chomp
          next if line.empty?
          next if line.start_with?("#")

          fields = line.split("\t", -1)
          next if fields.length < 2

          attrs = parse_row(fields)
          if attrs
            batch << attrs
            if batch.size >= 5000
              flush_batch!(batch)
              batch = []
            end
          end
        end
      end
      flush_batch!(batch) if batch.any?
    end

    private

    def tsv_path
      File.join(@dir, "cross_references.txt")
    end

    def ensure_source_present!
      if @download || !File.exist?(tsv_path)
        Rails.logger.info "[OpenbibleXrefsImporter] downloading #{SOURCE_URL}"
        FileUtils.mkdir_p(@dir)
        zip_path = File.join(@dir, "cross-references.zip")
        URI.open(SOURCE_URL) { |io| File.binwrite(zip_path, io.read) }
        system("unzip", "-o", zip_path, "-d", @dir.to_s, out: File::NULL) or raise "unzip failed"
        bump(:downloaded)
      end
    end

    REF_RE = /\A([0-9A-Za-z]+)\.(\d+)\.(\d+)\z/

    def parse_row(fields)
      from_raw = fields[0].to_s.strip
      to_raw   = fields[1].to_s.strip
      votes    = fields[2].to_i
      return nil if from_raw.empty? || to_raw.empty?

      from = parse_ref(from_raw) or begin
        bump(:from_unparsed)
        return nil
      end

      to_start, to_end = parse_to_range(to_raw)
      unless to_start
        bump(:to_unparsed)
        return nil
      end

      from_ref = lookup_ref(from[0], from[1], from[2])
      unless from_ref
        bump(:from_missing_canonical_ref)
        return nil
      end

      target_cw_start = canonical_work_for(to_start[0])
      unless target_cw_start
        bump(:to_unknown_book)
        return nil
      end

      # Cross-book target ranges (Lev.27.34-Num.1.1, 2Chr.36.22-Ezra.1.3,
      # etc.) are common in the OpenBible.info data — they connect the
      # last verse of one book to the first verse(s) of the next.
      # Resolve the end against its OWN canonical_work, not the start's.
      # When the books differ we can't represent it as a single range
      # over a single canonical_work, so we collapse to the start verse
      # only and tag the row.
      to_start_ord = lookup_ord(target_cw_start, to_start[1], to_start[2])
      unless to_start_ord
        bump(:to_missing_canonical_ref)
        return nil
      end

      target_cw_end = to_end ? canonical_work_for(to_end[0]) : target_cw_start
      target_cw     = target_cw_start
      to_end_ord    = if to_end.nil?
        to_start_ord
      elsif target_cw_end&.id == target_cw_start.id
        lookup_ord(target_cw_end, to_end[1], to_end[2]) || to_start_ord
      else
        # Cross-book range: collapse to the start endpoint.
        bump(:cross_book_range_collapsed)
        to_start_ord
      end

      # Defensive: skip rows where the resolved range would be backwards
      # (data error in the source — Postgres rejects the int4range otherwise).
      if to_end_ord < to_start_ord
        bump(:backwards_range_skipped)
        return nil
      end

      confidence = [[votes / 100.0, 0.0].max, 1.0].min.round(3)

      {
        source_canonical_work_id: from_ref.canonical_work_id,
        source_range:             "[#{from_ref.ord},#{from_ref.ord + 1})",
        target_canonical_work_id: target_cw.id,
        target_range:             "[#{to_start_ord},#{to_end_ord + 1})",
        relationship_type:        "parallels",
        confidence:               confidence,
        source_dataset:           SOURCE_DATASET,
        status:                   "approved",
        notes:                    "OpenBible.info CC BY 4.0 (#{votes} votes)",
        import_run_id:            @import_run.id,
        created_at:               Time.current,
        updated_at:               Time.current
      }
    end

    # OpenBible single ref: "Gen.1.1" → ["Gen", 1, 1]
    def parse_ref(s)
      m = REF_RE.match(s) or return nil
      [m[1], m[2].to_i, m[3].to_i]
    end

    # OpenBible to-range: "Gen.1.1" or "Gen.1.1-Gen.1.5"
    # Returns [start_parsed, end_parsed]; end_parsed is nil for single refs.
    def parse_to_range(s)
      if s.include?("-")
        a, b = s.split("-", 2)
        sp = parse_ref(a)
        ep = parse_ref(b)
        return [nil, nil] unless sp && ep
        [sp, ep]
      else
        sp = parse_ref(s)
        return [nil, nil] unless sp
        [sp, nil]
      end
    end

    def canonical_work_for(book_code)
      slug = BOOK_CODE_TO_KEY[book_code] or return nil
      @canonical_work_cache[slug] ||= CanonicalWork.find_by(slug: slug)
    end

    def lookup_ref(book_code, chapter, verse)
      cw = canonical_work_for(book_code) or return nil
      key = [cw.id, chapter, verse]
      @ref_cache[key] ||= CanonicalRef.where(canonical_work_id: cw.id, hierarchy: [chapter, verse]).first
    end

    def lookup_ord(canonical_work, chapter, verse)
      key = [canonical_work.id, chapter, verse]
      ref = (@ref_cache[key] ||= CanonicalRef.where(canonical_work_id: canonical_work.id, hierarchy: [chapter, verse]).first)
      ref&.ord
    end

    def flush_batch!(batch)
      CrossReference.insert_all(batch)
      bump(:rows_inserted, batch.size)
      if (@stats[:rows_inserted] || 0) % 25_000 < 5000
        $stdout.puts "[OpenbibleXrefsImporter] #{@stats[:rows_inserted]} inserted"
        $stdout.flush
      end
    end
  end
end
