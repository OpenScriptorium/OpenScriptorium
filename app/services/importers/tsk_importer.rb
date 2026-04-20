require "open-uri"

module Importers
  # Imports the Treasury of Scripture Knowledge (TSK) cross-references.
  #
  # Source: https://github.com/CrossReferences-org/bible-cross-references
  # Direct: KJV variant — crossreferences_kjv.tsv
  # License: CC BY-SA 4.0 (the underlying TSK is 1830s public domain;
  #          the digital edition with phrase anchors is CC BY-SA)
  # Volume: ~63,700 anchor entries → ~305,000 individual cross-references
  #
  # ## Format
  #
  # Tab-separated, with a header line. Five columns:
  #
  #   book  chapter  verse  anchor      references
  #   Gen   1        1      beginning   Prov 8:22-24|Prov 16:4|...
  #   Gen   1        1      God         Exod 20:11|Exod 31:18|...
  #
  # The `references` column is a pipe-separated list, each entry of
  # the form `Book chapter:verses` where `verses` may be:
  #
  #   * single verse:        `5`
  #   * range:               `5-9` (single chapter)
  #   * comma list:          `5, 7, 9` (single chapter)
  #   * mixed:               `5-7, 9, 12-14`
  #
  # Each individual verse-or-range becomes one CrossReference row.
  # The English `anchor` phrase is preserved on the CrossReference's
  # `notes` field so the verse-view can show which word triggered
  # the reference.
  class TskImporter < BaseImporter
    SOURCE_URL = "https://raw.githubusercontent.com/CrossReferences-org/bible-cross-references/main/kjv/crossreferences_kjv.tsv"
    DEFAULT_PATH = Rails.root.join("tmp/tsk/crossreferences_kjv.tsv")
    SOURCE_DATASET = "tsk".freeze

    # TSK uses common English abbreviations for biblical books, with
    # numbered books spelled "1 Sam" / "2 Cor" / etc. (space, not
    # period or hyphen).
    BOOK_NAME_TO_KEY = {
      "Gen"     => "genesis",     "Exod"   => "exodus",       "Lev"   => "leviticus",
      "Num"     => "numbers",     "Deut"   => "deuteronomy",
      "Josh"    => "joshua",      "Judg"   => "judges",       "Ruth"  => "ruth",
      "1 Sam"   => "1-samuel",    "2 Sam"  => "2-samuel",
      "1 Kgs"   => "1-kings",     "2 Kgs"  => "2-kings",
      "1 Chr"   => "1-chronicles", "2 Chr" => "2-chronicles",
      "Ezra"    => "ezra",        "Neh"    => "nehemiah",     "Esth"  => "esther",
      "Job"     => "job",         "Ps"     => "psalms",       "Prov"  => "proverbs",
      "Eccl"    => "ecclesiastes", "Song"  => "song-of-solomon",
      "Isa"     => "isaiah",      "Jer"    => "jeremiah",     "Lam"   => "lamentations",
      "Ezek"    => "ezekiel",     "Dan"    => "daniel",
      "Hos"     => "hosea",       "Joel"   => "joel",         "Amos"  => "amos",
      "Obad"    => "obadiah",     "Jonah"  => "jonah",        "Mic"   => "micah",
      "Nah"     => "nahum",       "Hab"    => "habakkuk",     "Zeph"  => "zephaniah",
      "Hag"     => "haggai",      "Zech"   => "zechariah",    "Mal"   => "malachi",
      "Matt"    => "matthew",     "Mark"   => "mark",         "Luke"  => "luke",
      "John"    => "john",        "Acts"   => "acts",         "Rom"   => "romans",
      "1 Cor"   => "1-corinthians", "2 Cor" => "2-corinthians",
      "Gal"     => "galatians",   "Eph"    => "ephesians",    "Phil"  => "philippians",
      "Col"     => "colossians",
      "1 Thess" => "1-thessalonians", "2 Thess" => "2-thessalonians",
      "1 Tim"   => "1-timothy",   "2 Tim"  => "2-timothy",
      "Titus"   => "titus",       "Phlm"   => "philemon",
      "Heb"     => "hebrews",     "Jas"    => "james",
      "1 Pet"   => "1-peter",     "2 Pet"  => "2-peter",
      "1 John"  => "1-john",      "2 John" => "2-john",       "3 John" => "3-john",
      "Jude"    => "jude",        "Rev"    => "revelation"
    }.freeze

    # The source-row book column uses the same abbreviations as the
    # references — wire it through the same map.
    SOURCE_BOOK_ALIASES = {
      "Eccles" => "Eccl"
    }.freeze

    def initialize(path: nil, download: nil, **opts)
      super(**opts)
      @path = path || DEFAULT_PATH
      @download = download.nil? ? !File.exist?(@path) : download
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

      Rails.logger.info "[TskImporter] wiping existing TSK cross_references"
      CrossReference.where(source_dataset: SOURCE_DATASET).delete_all

      @canonical_work_cache = {}
      @ref_cache = {}

      Rails.logger.info "[TskImporter] parsing #{@path}"
      batch = []
      File.open(@path, "r:bom|utf-8") do |f|
        f.each_line.with_index do |line, idx|
          next if idx == 0
          line = line.chomp
          next if line.empty?

          fields = line.split("\t", -1)
          next if fields.length < 5

          process_row(fields, batch)
          if batch.size >= 5000
            flush_batch!(batch)
            batch = []
          end
        end
      end
      flush_batch!(batch) if batch.any?
    end

    private

    def ensure_source_present!
      if @download || !File.exist?(@path)
        Rails.logger.info "[TskImporter] downloading #{SOURCE_URL}"
        FileUtils.mkdir_p(File.dirname(@path))
        URI.open(SOURCE_URL) { |io| File.binwrite(@path, io.read) }
        bump(:downloaded)
      end
    end

    def process_row(fields, batch)
      source_book = SOURCE_BOOK_ALIASES.fetch(fields[0].to_s.strip, fields[0].to_s.strip)
      source_ch   = fields[1].to_i
      source_v    = fields[2].to_i
      anchor      = fields[3].to_s.strip
      refs_str    = fields[4].to_s.strip
      return if refs_str.empty?

      source_ref = lookup_ref(source_book, source_ch, source_v)
      unless source_ref
        bump(:source_missing_canonical_ref)
        return
      end

      refs_str.split("|").each do |ref_chunk|
        parsed_targets = parse_target_chunk(ref_chunk.strip)
        if parsed_targets.empty?
          bump(:target_unparsed)
          next
        end
        parsed_targets.each do |target_book, target_ch, v_start, v_end|
          target_cw = canonical_work_for(target_book)
          unless target_cw
            bump(:target_unknown_book)
            next
          end
          start_ord = lookup_ord(target_cw, target_ch, v_start)
          end_ord   = lookup_ord(target_cw, target_ch, v_end)
          unless start_ord && end_ord
            bump(:target_missing_canonical_ref)
            next
          end
          if end_ord < start_ord
            start_ord, end_ord = end_ord, start_ord
            bump(:target_range_swapped)
          end

          batch << {
            source_canonical_work_id: source_ref.canonical_work_id,
            source_range:             "[#{source_ref.ord},#{source_ref.ord + 1})",
            target_canonical_work_id: target_cw.id,
            target_range:             "[#{start_ord},#{end_ord + 1})",
            relationship_type:        "parallels",
            confidence:               1.0,
            source_dataset:           SOURCE_DATASET,
            status:                   "approved",
            notes:                    "TSK / Treasury of Scripture Knowledge (anchor: #{anchor})",
            import_run_id:            @import_run.id,
            created_at:               Time.current,
            updated_at:               Time.current
          }
        end
      end
    end

    # Parse a single target reference chunk like:
    #   "Gen 1:1"           → [["Gen", 1, 1, 1]]
    #   "Gen 1:1-5"         → [["Gen", 1, 1, 5]]
    #   "Gen 1:1, 3"        → [["Gen", 1, 1, 1], ["Gen", 1, 3, 3]]
    #   "Gen 1:1, 3-5"      → [["Gen", 1, 1, 1], ["Gen", 1, 3, 5]]
    #   "Ps 33:6, 9"        → [["Ps", 33, 6, 6], ["Ps", 33, 9, 9]]
    #
    # Cross-chapter ranges (Gen 5:32-6:1) are not in the TSK output;
    # if encountered, we take only the start endpoint.
    REF_CHUNK_RE = /\A(?<book>(?:[1-3]\s)?[A-Za-z]+(?:\s[A-Za-z]+)?)\s+(?<ch>\d+):(?<verses>[\d,\s\-]+)\z/

    def parse_target_chunk(s)
      return [] if s.empty?
      m = REF_CHUNK_RE.match(s) or return []
      book = m[:book].strip
      chapter = m[:ch].to_i
      verse_expr = m[:verses].strip

      # Split on commas. Each segment is either a single verse or a
      # `from-to` range.
      result = []
      verse_expr.split(",").each do |seg|
        seg = seg.strip
        if seg.include?("-")
          a, b = seg.split("-", 2).map { |x| x.strip.to_i }
          # Defensive: source data sometimes encodes a backwards range
          # via OCR or transcription error. Drop the segment rather
          # than producing an invalid int4range.
          next unless a > 0 && b >= a
          result << [book, chapter, a, b]
        elsif seg =~ /\A\d+\z/
          v = seg.to_i
          result << [book, chapter, v, v]
        end
      end
      result
    end

    def canonical_work_for(book_name)
      slug = BOOK_NAME_TO_KEY[book_name] or return nil
      @canonical_work_cache[slug] ||= CanonicalWork.find_by(slug: slug)
    end

    def lookup_ref(book_name, chapter, verse)
      cw = canonical_work_for(book_name) or return nil
      key = [cw.id, chapter, verse]
      @ref_cache[key] ||= CanonicalRef.where(canonical_work_id: cw.id, hierarchy: [chapter, verse]).first
    end

    def lookup_ord(canonical_work, chapter, verse)
      key = [canonical_work.id, chapter, verse]
      ref = (@ref_cache[key] ||= CanonicalRef.where(canonical_work_id: canonical_work.id, hierarchy: [chapter, verse]).first)
      ref&.ord
    end

    def flush_batch!(batch)
      # Deduplicate within batch (source data has duplicate rows)
      before = batch.size
      batch.uniq! { |r| [r[:source_canonical_work_id], r[:target_canonical_work_id], r[:source_range], r[:target_range]] }
      bump(:duplicates_skipped, before - batch.size) if before > batch.size
      CrossReference.insert_all(batch)
      bump(:rows_inserted, batch.size)
      if (@stats[:rows_inserted] || 0) % 25_000 < 5000
        $stdout.puts "[TskImporter] #{@stats[:rows_inserted]} inserted"
        $stdout.flush
      end
    end
  end
end
