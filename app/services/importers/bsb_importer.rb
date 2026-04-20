require "open-uri"

module Importers
  # Imports the Berean Standard Bible (BSB) from bereanbible.com.
  #
  # Source format: a single tab-separated text file. The first three
  # rows are metadata + header. Each subsequent row is one verse:
  #
  #     Genesis 1:1\tIn the beginning God created the heavens and the earth.
  #     Genesis 1:2\tNow the earth was formless and void...
  #
  # The reference parses to a (canonical_work, chapter, verse) tuple.
  # The importer creates the BSB Work, ensures the canonical_work for
  # each book exists, creates a canonical_ref for each verse if missing,
  # and writes a WorkUnit aligned to that canonical_ref.
  #
  # Idempotent: re-runs over an unchanged source produce zero diffs.
  class BsbImporter < BaseImporter
    SOURCE_URL = "https://bereanbible.com/bsb.txt"
    DEFAULT_PATH = Rails.root.join("tmp/bsb/bsb.txt")

    # Maps the human-readable book name from BSB references to the
    # canonical_works.slug we seeded in db/seeds/canonical_works.rb.
    BOOK_SLUGS = {
      "Genesis" => "genesis", "Exodus" => "exodus", "Leviticus" => "leviticus",
      "Numbers" => "numbers", "Deuteronomy" => "deuteronomy",
      "Joshua" => "joshua", "Judges" => "judges", "Ruth" => "ruth",
      "1 Samuel" => "1-samuel", "2 Samuel" => "2-samuel",
      "1 Kings" => "1-kings", "2 Kings" => "2-kings",
      "1 Chronicles" => "1-chronicles", "2 Chronicles" => "2-chronicles",
      "Ezra" => "ezra", "Nehemiah" => "nehemiah", "Esther" => "esther",
      "Job" => "job", "Psalm" => "psalms", "Psalms" => "psalms",
      "Proverbs" => "proverbs", "Ecclesiastes" => "ecclesiastes",
      "Song of Solomon" => "song-of-solomon", "Songs of Solomon" => "song-of-solomon",
      "Song of Songs" => "song-of-solomon",
      "Isaiah" => "isaiah", "Jeremiah" => "jeremiah",
      "Lamentations" => "lamentations", "Ezekiel" => "ezekiel",
      "Daniel" => "daniel", "Hosea" => "hosea", "Joel" => "joel",
      "Amos" => "amos", "Obadiah" => "obadiah", "Jonah" => "jonah",
      "Micah" => "micah", "Nahum" => "nahum", "Habakkuk" => "habakkuk",
      "Zephaniah" => "zephaniah", "Haggai" => "haggai",
      "Zechariah" => "zechariah", "Malachi" => "malachi",

      "Matthew" => "matthew", "Mark" => "mark", "Luke" => "luke", "John" => "john",
      "Acts" => "acts", "Romans" => "romans",
      "1 Corinthians" => "1-corinthians", "2 Corinthians" => "2-corinthians",
      "Galatians" => "galatians", "Ephesians" => "ephesians",
      "Philippians" => "philippians", "Colossians" => "colossians",
      "1 Thessalonians" => "1-thessalonians", "2 Thessalonians" => "2-thessalonians",
      "1 Timothy" => "1-timothy", "2 Timothy" => "2-timothy",
      "Titus" => "titus", "Philemon" => "philemon",
      "Hebrews" => "hebrews", "James" => "james",
      "1 Peter" => "1-peter", "2 Peter" => "2-peter",
      "1 John" => "1-john", "2 John" => "2-john", "3 John" => "3-john",
      "Jude" => "jude", "Revelation" => "revelation"
    }.freeze

    # Reference grammar:
    #   "Genesis 1:1"            → ("Genesis", 1, 1)
    #   "1 Samuel 17:50"         → ("1 Samuel", 17, 50)
    #   "Song of Solomon 2:3"    → ("Song of Solomon", 2, 3)
    REF_REGEX = /\A(?<book>(?:\d\s)?[A-Za-z][A-Za-z\s]*?)\s+(?<ch>\d+):(?<v>\d+)\z/

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

    def perform
      ensure_source_present!

      bsb = ensure_work
      kjv_scheme = VersificationScheme.find_by!(code: "KJV")
      canonical_work_cache = {}

      # Pre-load existing work_units for this work to avoid N+1 SELECTs.
      existing_units = WorkUnit.where(work_id: bsb.id)
                               .pluck(:canonical_ref_id, :id, :body, :ord)
      @existing_unit_map = {}
      existing_units.each do |cref_id, id, body, ord|
        @existing_unit_map[cref_id] = { id: id, body: body, ord: ord }
      end

      @wu_insert_batch = []
      @wu_update_batch = []

      File.open(@path, "r:bom|utf-8") do |f|
        f.each_line.with_index do |line, idx|
          # First three lines are metadata + header
          next if idx < 3

          ref_str, text = line.chomp.split("\t", 2)
          next if ref_str.blank? || text.blank?

          parsed = parse_ref(ref_str) or begin
            bump(:unparseable)
            Rails.logger.warn "[BsbImporter] could not parse reference: #{ref_str.inspect}"
            next
          end

          book, chapter, verse = parsed
          slug = BOOK_SLUGS[book] or begin
            bump(:unknown_book)
            Rails.logger.warn "[BsbImporter] unknown book: #{book.inspect}"
            next
          end

          canonical_work = canonical_work_cache[slug] ||=
            CanonicalWork.find_by!(slug: slug)

          canonical_ref = ensure_canonical_ref(canonical_work, [chapter, verse])
          collect_work_unit(bsb, canonical_ref, chapter, verse, text)
        end
      end

      flush_work_unit_inserts!(bsb)
      flush_work_unit_updates!

      bsb.update!(last_imported_at: Time.current,
                  imported_at: bsb.imported_at || Time.current,
                  source_revision: source_revision)
    end

    private

    def ensure_source_present!
      if @download || !File.exist?(@path)
        Rails.logger.info "[BsbImporter] downloading from #{SOURCE_URL}"
        FileUtils.mkdir_p(File.dirname(@path))
        URI.open(SOURCE_URL) { |io| File.binwrite(@path, io.read) }
        bump(:downloaded)
      end
    end

    def ensure_work
      # BSB is released into the public domain by the Berean Bible
      # Translation Committee — there is no "BSB license," just PD.
      license = License.find_by!(name: "Public Domain")
      Work.find_or_initialize_by(slug: "bsb").tap do |w|
        w.assign_attributes(
          title: "Berean Standard Bible",
          work_type: "scripture_translation",
          language: "en",
          traditions: ["χ-protestant"],
          genre: "translation",
          license: license,
          default_versification_scheme: VersificationScheme.find_by(code: "KJV"),
          source_url: "https://berean.bible/",
          publication_year: 2022,
          description: "The Berean Standard Bible (BSB) is a modern English translation of the Bible released into the public domain by the Berean Bible Translation Committee."
        )
        stamp(w)
        w.save!
      end
    end

    def parse_ref(ref_str)
      m = REF_REGEX.match(ref_str.strip)
      return nil unless m
      [m[:book].strip, m[:ch].to_i, m[:v].to_i]
    end

    # Collect a work_unit row into the appropriate batch (insert or update).
    def collect_work_unit(work, canonical_ref, chapter, verse, text)
      existing = @existing_unit_map[canonical_ref.id]
      now = Time.current

      if existing
        # Only update if body actually changed
        if existing[:body] != text.strip
          @wu_update_batch << {
            id: existing[:id],
            work_id: work.id,
            ord: existing[:ord],
            body: text.strip,
            label: "#{chapter}:#{verse}",
            canonical_alignment_type: "exact",
            markup: {},
            import_run_id: @import_run.id,
            created_at: now,
            updated_at: now
          }
          bump(:work_units_updated)
          flush_work_unit_updates! if @wu_update_batch.size >= 2000
        else
          bump(:work_units_unchanged)
        end
      else
        ord = next_work_unit_ord(work)
        @wu_insert_batch << {
          work_id: work.id,
          canonical_ref_id: canonical_ref.id,
          ord: ord,
          label: "#{chapter}:#{verse}",
          body: text.strip,
          canonical_alignment_type: "exact",
          markup: {},
          import_run_id: @import_run.id,
          created_at: now,
          updated_at: now
        }
        bump(:work_units_created)
        flush_work_unit_inserts!(work) if @wu_insert_batch.size >= 2000
      end
    end

    def flush_work_unit_inserts!(work)
      return if @wu_insert_batch.empty?
      WorkUnit.insert_all(@wu_insert_batch)
      @wu_insert_batch = []
    end

    def flush_work_unit_updates!
      return if @wu_update_batch.empty?
      # Batch updates via upsert_all on the primary key
      WorkUnit.upsert_all(@wu_update_batch, unique_by: :id)
      @wu_update_batch = []
    end

    def next_work_unit_ord(work)
      @next_ord ||= {}
      @next_ord[work.id] ||= (WorkUnit.where(work_id: work.id).maximum(:ord) || 0)
      @next_ord[work.id] += 1
    end

    def source_revision
      File.exist?(@path) ? File.mtime(@path).utc.iso8601 : nil
    end
  end
end
