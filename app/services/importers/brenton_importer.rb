require "open-uri"

module Importers
  # Imports Sir Lancelot Brenton's English translation of the Septuagint
  # (1851), distributed by ebible.org as VPL (verse-per-line) plain text.
  #
  # Brenton was published in 1851; the translation is unambiguously
  # public domain everywhere. ebible.org confirms this on their
  # eng-Brenton metadata page.
  #
  # Source format is one verse per line:
  #
  #     GEN 1:1 In the beginning God made the heaven and the earth.
  #
  # The book code is a 3-letter USFM-style abbreviation. We map each
  # to a canonical_works slug. Brenton uses LXX versification for the
  # divergent books (Psalms, Jeremiah, Job), so those map to the
  # `psalms-lxx`, `jeremiah-lxx`, `job-lxx` canonical_works that the
  # Rahlfs importer also targets.
  class BrentonImporter < BaseImporter
    SOURCE_URL = "https://ebible.org/Scriptures/eng-Brenton_vpl.zip"
    DEFAULT_PATH = Rails.root.join("tmp/brenton/brenton_vpl.txt")

    BOOK_MAP = {
      # Hebrew Bible — books that align verse-by-verse with MT/KJV
      "GEN" => "genesis",
      "EXO" => "exodus",
      "LEV" => "leviticus",
      "NUM" => "numbers",
      "DEU" => "deuteronomy",
      "JOS" => "joshua",
      "JDG" => "judges",
      "RUT" => "ruth",
      "1SA" => "1-samuel",
      "2SA" => "2-samuel",
      "1KI" => "1-kings",
      "2KI" => "2-kings",
      "1CH" => "1-chronicles",
      "2CH" => "2-chronicles",
      "EZR" => "ezra",
      "NEH" => "nehemiah",
      "EST" => "esther",
      "PRO" => "proverbs",
      "ECC" => "ecclesiastes",
      "SOL" => "song-of-solomon",
      "ISA" => "isaiah",
      "LAM" => "lamentations",
      "EZE" => "ezekiel",
      "DNG" => "daniel",     # Brenton calls his LXX Daniel "DNG" (Daniel Greek)
      "DAN" => "daniel",     # in case ebible variant uses DAN
      "HOS" => "hosea",
      "JOE" => "joel",
      "AMO" => "amos",
      "OBA" => "obadiah",
      "JON" => "jonah",
      "MIC" => "micah",
      "NAH" => "nahum",
      "HAB" => "habakkuk",
      "ZEP" => "zephaniah",
      "HAG" => "haggai",
      "ZEC" => "zechariah",
      "MAL" => "malachi",

      # Books with LXX-specific versification — map to LXX canonical_works
      "PSA" => "psalms-lxx",
      "JER" => "jeremiah-lxx",
      "JOB" => "job-lxx",

      # Apocrypha / deuterocanon
      "TOB" => "tobit",
      "JDT" => "judith",
      "ESG" => "esther-greek",
      "WIS" => "wisdom",
      "SIR" => "sirach",
      "BAR" => "baruch",
      "EPJ" => "letter-of-jeremiah",
      "SUS" => "susanna",
      "BEL" => "bel-and-the-dragon",
      "1MA" => "1-maccabees",
      "2MA" => "2-maccabees",
      "3MA" => "3-maccabees",
      "4MA" => "4-maccabees",
      "1ES" => "1-esdras",
      "2ES" => "2-esdras",
      "PRM" => "prayer-of-manasseh"
    }.freeze

    REF_REGEX = /\A(?<book>[A-Z0-9]{3})\s+(?<ch>\d+):(?<v>\d+)\s+(?<text>.+)\z/

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
      "vpl"
    end

    def transactional?
      false
    end

    def perform
      ensure_source_present!

      @license = License.find_by!(name: "Public Domain")
      @lxx_scheme = VersificationScheme.find_by!(code: "LXX")
      @work = ensure_work
      @canonical_work_cache = {}

      File.foreach(@path) do |line|
        line = line.chomp
        next if line.empty?

        m = REF_REGEX.match(line)
        unless m
          bump(:unparseable_lines)
          next
        end

        book_code = m[:book]
        slug = BOOK_MAP[book_code]
        unless slug
          bump(:skipped_unmapped_book)
          next
        end

        chapter = m[:ch].to_i
        verse_n = m[:v].to_i
        text    = m[:text].strip

        process_verse(slug, chapter, verse_n, text)
      end

      @work.update!(last_imported_at: Time.current,
                    imported_at: @work.imported_at || Time.current,
                    source_revision: source_revision)
    end

    private

    def ensure_source_present!
      if @download || !File.exist?(@path)
        FileUtils.mkdir_p(File.dirname(@path))
        zip_path = @path.to_s.sub(/\.txt\z/, ".zip")
        Rails.logger.info "[BrentonImporter] downloading #{SOURCE_URL}"
        URI.open(SOURCE_URL) { |io| File.binwrite(zip_path, io.read) }
        # Use system unzip rather than adding rubyzip as a dependency.
        # -p extracts to stdout; we redirect into the target file.
        File.binwrite(@path, %x(unzip -p #{zip_path.shellescape} '*_vpl.txt'))
        bump(:downloaded)
      end
    end

    def ensure_work
      Work.find_or_initialize_by(slug: "brenton-lxx").tap do |w|
        w.assign_attributes(
          title: "Brenton's English Septuagint",
          native_title: "The Septuagint Version of the Old Testament: According to the Vatican Text, Translated into English",
          work_type: "scripture_translation",
          language: "en",
          tradition: "lxx_translation",
          genre: "translation",
          license: @license,
          default_versification_scheme: @lxx_scheme,
          source_url: "https://ebible.org/find/details.php?id=eng-Brenton",
          publication_year: 1851,
          has_word_data: false,
          description: "Sir Lancelot Charles Lee Brenton's English translation of the Greek Septuagint, published in 1851. Translated from the Vaticanus-based text. The standard public-domain English translation of the LXX, including the apocrypha. Pre-critical and archaic in language, but freely usable everywhere."
        )
        stamp(w)
        w.save!
      end
    end

    def process_verse(slug, chapter, verse_n, text)
      canonical_work = (@canonical_work_cache[slug] ||= CanonicalWork.find_by(slug: slug))
      unless canonical_work
        bump(:missing_canonical_work)
        Rails.logger.warn "[BrentonImporter] no canonical_work for slug=#{slug.inspect}"
        return
      end

      ActiveRecord::Base.transaction do
        canonical_ref = ensure_canonical_ref(canonical_work, chapter, verse_n)

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

        bump(:verses_processed)
      end

      if (@stats[:verses_processed] % 5000).zero?
        puts "[BrentonImporter] #{@stats[:verses_processed]} verses"
        $stdout.flush
      end
    end

    def ensure_canonical_ref(canonical_work, chapter, verse_n)
      hierarchy = [chapter, verse_n]
      ref = CanonicalRef.where(
        canonical_work_id: canonical_work.id,
        hierarchy: hierarchy
      ).first
      return ref if ref

      next_ord = (CanonicalRef.where(canonical_work_id: canonical_work.id).maximum(:ord) || 0) + 1
      ref = CanonicalRef.new(
        canonical_work: canonical_work,
        ord: next_ord,
        hierarchy: hierarchy,
        display_label: "#{canonical_work.title} #{chapter}:#{verse_n}",
        osis_id: canonical_work.osis_book_id && "#{canonical_work.osis_book_id}.#{chapter}.#{verse_n}"
      )
      stamp(ref)
      ref.save!
      bump(:canonical_refs_created)
      ref
    end

    def next_work_unit_ord
      @next_ord ||= (WorkUnit.where(work_id: @work.id).maximum(:ord) || 0)
      @next_ord += 1
    end

    def source_revision
      File.exist?(@path) ? File.mtime(@path).utc.iso8601 : nil
    end
  end
end
