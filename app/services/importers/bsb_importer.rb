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

          canonical_ref = ensure_canonical_ref(canonical_work, chapter, verse)
          ensure_work_unit(bsb, canonical_ref, chapter, verse, text)
        end
      end

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

    # Compute the canonical_refs.ord by counting how many refs already
    # exist for this canonical_work plus 1. Since BSB iterates verses in
    # canonical order, this gives a stable sequential ordinal per work.
    def ensure_canonical_ref(canonical_work, chapter, verse)
      hierarchy = [chapter, verse]
      ref = CanonicalRef
              .where(canonical_work_id: canonical_work.id, hierarchy: hierarchy)
              .first
      return ref if ref

      next_ord = (CanonicalRef.where(canonical_work_id: canonical_work.id).maximum(:ord) || 0) + 1
      ref = CanonicalRef.new(
        canonical_work: canonical_work,
        ord: next_ord,
        hierarchy: hierarchy,
        display_label: "#{canonical_work.title} #{chapter}:#{verse}",
        osis_id: canonical_work.osis_book_id && "#{canonical_work.osis_book_id}.#{chapter}.#{verse}"
      )
      stamp(ref)
      ref.save!
      bump(:canonical_refs_created)
      ref
    end

    def ensure_work_unit(work, canonical_ref, chapter, verse, text)
      unit = WorkUnit.find_or_initialize_by(work_id: work.id, canonical_ref_id: canonical_ref.id)
      unit_was_new = unit.new_record?

      next_ord = unit_was_new ? next_work_unit_ord(work) : unit.ord
      unit.assign_attributes(
        ord: next_ord,
        label: "#{chapter}:#{verse}",
        body: text.strip,
        canonical_alignment_type: "exact"
      )

      stamp(unit)
      if unit.changed?
        unit.save!
        bump(unit_was_new ? :work_units_created : :work_units_updated)
      else
        bump(:work_units_unchanged)
      end
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
