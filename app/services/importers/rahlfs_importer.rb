require "csv"
require "open-uri"

module Importers
  # Imports the Rahlfs Septuagint (1935) Greek text.
  #
  # ## Licensing
  #
  # Alfred Rahlfs (1865–1935) edited the standard Septuagint published in
  # 1935. Under Canada's life+50 copyright term (in force until 2022 and
  # grandfathered after the 2022 extension), Rahlfs entered the public
  # domain in Canada on January 1, 1986. The Open Scriptorium production
  # server is hosted in Toronto, so this is the relevant jurisdiction.
  #
  # **The Greek text itself is unambiguously public domain in Canada/EU.**
  #
  # We download from Eliran Wong's `LXX-Rahlfs-1935` repository, which
  # carries a CC BY-NC-SA 4.0 license on Wong's editorial contributions
  # (his morphology corrections, English glosses, lemma normalizations,
  # bridging tables to the NT). **We DO NOT import any of Wong's editorial
  # contributions** — only the underlying public-domain Rahlfs text:
  #
  #   * `01_wordlist_unicode/text_accented.csv` — accented Greek surface
  #     forms (1 row per word, columns: word_id, position, surface)
  #   * `08_versification/ccat/E-verse.csv` — verse boundaries
  #     (columns: starting_word_id, starting_word_id_dup, "「Book Ch:V」")
  #
  # The first column of each file is the underlying Rahlfs text content
  # (Greek words, verse references). Wong's NC-licensed columns
  # (morphology, glosses, etc.) live in OTHER files in OTHER directories
  # of his repo and we never read them.
  #
  # ## What we import
  #
  # All Rahlfs LXX books that align verse-by-verse with the MT/KJV
  # versification — which is most of them, plus the apocrypha. Skipped:
  #
  #   * Ps    (LXX numbering diverges from MT from Psalm 9 onwards)
  #   * Jer   (LXX is significantly shorter and reordered)
  #   * Job   (LXX is ~1/6 shorter than MT)
  #   * DanTh, BelTh, SusTh (Theodotion variants — alternative recensions)
  #   * JoshB, JudgB        (alternative manuscript traditions)
  #   * TobS                (Sinaiticus recension; we use TobBA as primary)
  #
  # These are deferred until we add LXX-specific canonical_works for
  # the divergent books.
  class RahlfsImporter < BaseImporter
    BASE_URL = "https://raw.githubusercontent.com/eliranwong/LXX-Rahlfs-1935/master"
    DEFAULT_DIR = Rails.root.join("tmp/rahlfs")

    TEXT_PATH    = "01_wordlist_unicode/text_accented.csv"
    VERSE_PATH   = "08_versification/ccat/E-verse.csv"

    # Map Rahlfs book codes to canonical_works slugs. Books not in this
    # map are silently skipped (Theodotion variants, alt recensions).
    BOOK_MAP = {
      "Gen"     => "genesis",
      "Exod"    => "exodus",
      "Lev"     => "leviticus",
      "Num"     => "numbers",
      "Deut"    => "deuteronomy",
      "JoshA"   => "joshua",
      "JudgA"   => "judges",
      "Ruth"    => "ruth",
      "1Sam/K"  => "1-samuel",
      "2Sam/K"  => "2-samuel",
      "1/3Kgs"  => "1-kings",
      "2/4Kgs"  => "2-kings",
      "1Chr"    => "1-chronicles",
      "2Chr"    => "2-chronicles",
      "1Esdr"   => "1-esdras",
      "2Esdr"   => "2-esdras",
      "Esth"    => "esther-greek",
      "Jdt"     => "judith",
      "TobBA"   => "tobit",
      "1Mac"    => "1-maccabees",
      "2Mac"    => "2-maccabees",
      "3Mac"    => "3-maccabees",
      "4Mac"    => "4-maccabees",
      "Prov"    => "proverbs",
      "Qoh"     => "ecclesiastes",
      "Cant"    => "song-of-solomon",
      "Wis"     => "wisdom",
      "Sir"     => "sirach",
      "PsSol"   => "psalms-of-solomon",
      "Od"      => "odes",
      "Hos"     => "hosea",
      "Amos"    => "amos",
      "Mic"     => "micah",
      "Joel"    => "joel",
      "Obad"    => "obadiah",
      "Jonah"   => "jonah",
      "Nah"     => "nahum",
      "Hab"     => "habakkuk",
      "Zeph"    => "zephaniah",
      "Hag"     => "haggai",
      "Zech"    => "zechariah",
      "Mal"     => "malachi",
      "Isa"     => "isaiah",
      "Bar"     => "baruch",
      "Lam"     => "lamentations",
      "EpJer"   => "letter-of-jeremiah",
      "Ezek"    => "ezekiel",
      "Sus"     => "susanna",
      "Dan"     => "daniel",
      "Bel"     => "bel-and-the-dragon"
      # Deferred: Ps, Jer, Job, DanTh, BelTh, SusTh, JoshB, JudgB, TobS
    }.freeze

    def initialize(dir: nil, download: nil, **opts)
      super(**opts)
      @dir = dir || DEFAULT_DIR
      @download = download.nil? ? true : download
    end

    protected

    def source_url
      "#{BASE_URL}/#{TEXT_PATH}"
    end

    def source_format
      "csv"
    end

    def transactional?
      false
    end

    def perform
      ensure_source_files!

      @license = License.find_by!(name: "Public Domain")
      @lxx_scheme = VersificationScheme.find_by!(code: "LXX")
      @work = ensure_work
      @canonical_work_cache = {}

      # Load all Greek words into memory keyed by global word_id.
      # The text_accented.csv file is ~10 MB; this fits comfortably.
      Rails.logger.info "[RahlfsImporter] loading word table"
      @words_by_id = load_words_table
      Rails.logger.info "[RahlfsImporter] loaded #{@words_by_id.size} words"

      # Load verse boundaries with their references.
      verses = load_verses_table
      Rails.logger.info "[RahlfsImporter] loaded #{verses.size} verses"

      # Process each verse: extract words from start..next_start-1.
      verses.each_with_index do |(start_word_id, ref_str), idx|
        end_word_id = idx + 1 < verses.size ? verses[idx + 1].first - 1 : @words_by_id.keys.max
        process_verse(start_word_id, end_word_id, ref_str)

        if (idx + 1) % 1000 == 0
          puts "[RahlfsImporter] #{idx + 1}/#{verses.size} verses, processed=#{@stats[:verses_processed]}, skipped=#{@stats[:skipped_unmapped_book] || 0}"
          $stdout.flush
        end
      end

      @work.update!(last_imported_at: Time.current,
                    imported_at: @work.imported_at || Time.current,
                    source_revision: source_revision)
    end

    private

    def ensure_source_files!
      FileUtils.mkdir_p(File.join(@dir, "01_wordlist_unicode"))
      FileUtils.mkdir_p(File.join(@dir, "08_versification/ccat"))

      [TEXT_PATH, VERSE_PATH].each do |rel|
        local = File.join(@dir, rel)
        if @download || !File.exist?(local)
          url = "#{BASE_URL}/#{rel}"
          Rails.logger.info "[RahlfsImporter] downloading #{url}"
          URI.open(url) { |io| File.binwrite(local, io.read) }
          bump(:downloaded)
        end
      end
    end

    def ensure_work
      Work.find_or_initialize_by(slug: "rahlfs-lxx").tap do |w|
        w.assign_attributes(
          title: "Rahlfs Septuagint (1935)",
          native_title: "Septuaginta",
          work_type: "scripture_original",
          language: "el-koine",
          tradition: "septuagint",
          genre: "original",
          license: @license,
          default_versification_scheme: @lxx_scheme,
          source_url: "https://github.com/eliranwong/LXX-Rahlfs-1935",
          publication_year: 1935,
          has_word_data: false,
          description: "Alfred Rahlfs's edition of the Septuagint, published 1935. The standard scholarly edition of the Greek translation of the Hebrew Bible plus the deuterocanonical and apocryphal books transmitted in Greek. Public domain in Canada and the European Union; the Open Scriptorium production server is hosted in Toronto. Greek text only — morphology and lemma data deferred to a separate import."
        )
        stamp(w)
        w.save!
      end
    end

    # Returns a Hash{Integer word_id => String surface}.
    # text_accented.csv is tab-separated: word_id, position, surface.
    def load_words_table
      table = {}
      File.foreach(File.join(@dir, TEXT_PATH)) do |line|
        line = line.chomp
        next if line.empty?
        parts = line.split("\t")
        next if parts.size < 3
        wid = parts[0].to_i
        table[wid] = parts[2]
      end
      table
    end

    # Returns Array of [start_word_id (Integer), ref_str (String)] in
    # the order they appear in the file.
    def load_verses_table
      verses = []
      File.foreach(File.join(@dir, VERSE_PATH)) do |line|
        line = line.chomp
        next if line.empty?
        parts = line.split("\t")
        next if parts.size < 3
        # Reference is wrapped in 「japanese-style brackets」
        ref = parts[2].sub(/\A「/, "").sub(/」\z/, "").strip
        verses << [parts[0].to_i, ref]
      end
      verses
    end

    # Reference grammars from Rahlfs E-verse.csv:
    #
    #   * Standard:        "Gen 1:1"  "1Sam/K 17:50"  "1/3Kgs 8:22"
    #   * Subverse:        "1/3Kgs 10:22a"  "1/3Kgs 12:24p"
    #                      Letter suffix → hierarchy [ch, v, part]
    #                      where part = letter index (a=1, b=2, ...).
    #                      Rahlfs has these "miscellanies" mostly in
    #                      1 Kings 10 and 12.
    #   * Single-chapter:  "Sus 5"  "Bel 12"  "Obad 8"  "Jude 14"
    #                      No colon — these books are often cited as
    #                      just verse numbers in scholarship. We map to
    #                      [1, verse_n] so they align with how BSB cites
    #                      them ("Jude 1:14") and with our existing
    #                      canonical_refs.
    REF_VV_REGEX     = /\A(?<book>.+?)\s+(?<ch>\d+):(?<v>\d+)(?<part>[a-z])?\z/
    REF_SINGLE_REGEX = /\A(?<book>.+?)\s+(?<v>\d+)\z/

    def process_verse(start_word_id, end_word_id, ref_str)
      book_code = nil
      chapter   = nil
      verse_n   = nil
      part      = nil

      if (m = REF_VV_REGEX.match(ref_str))
        book_code = m[:book]
        chapter   = m[:ch].to_i
        verse_n   = m[:v].to_i
        part      = m[:part] ? (m[:part].ord - 'a'.ord + 1) : nil
      elsif (m = REF_SINGLE_REGEX.match(ref_str))
        book_code = m[:book]
        # Single-chapter books: bare verse number maps to chapter 1.
        chapter   = 1
        verse_n   = m[:v].to_i
      else
        bump(:unparseable_refs)
        Rails.logger.warn "[RahlfsImporter] could not parse #{ref_str.inspect}"
        return
      end

      slug = BOOK_MAP[book_code]
      unless slug
        bump(:skipped_unmapped_book)
        return
      end

      canonical_work = (@canonical_work_cache[slug] ||= CanonicalWork.find_by(slug: slug))
      unless canonical_work
        bump(:missing_canonical_work)
        Rails.logger.warn "[RahlfsImporter] no canonical_work for slug=#{slug.inspect}"
        return
      end

      # Concatenate the words for this verse in their stored order.
      surfaces = (start_word_id..end_word_id).map { |id| @words_by_id[id] }.compact
      body = surfaces.join(" ").strip
      return if body.blank?

      label = part ? "#{chapter}:#{verse_n}#{('a'.ord + part - 1).chr}" : "#{chapter}:#{verse_n}"

      ActiveRecord::Base.transaction do
        canonical_ref = ensure_canonical_ref(canonical_work, chapter, verse_n, part)

        work_unit = WorkUnit.find_or_initialize_by(
          work_id: @work.id,
          canonical_ref_id: canonical_ref.id
        )
        if work_unit.new_record?
          work_unit.assign_attributes(
            ord: next_work_unit_ord,
            label: label,
            canonical_alignment_type: "exact"
          )
        end
        work_unit.body = body
        stamp(work_unit)
        work_unit.save!

        bump(:verses_processed)
        bump(:subverses_processed) if part
      end
    end

    def ensure_canonical_ref(canonical_work, chapter, verse_n, part = nil)
      hierarchy = part ? [chapter, verse_n, part] : [chapter, verse_n]
      ref = CanonicalRef.where(
        canonical_work_id: canonical_work.id,
        hierarchy: hierarchy
      ).first
      return ref if ref

      part_suffix = part ? ('a'.ord + part - 1).chr : ""
      next_ord = (CanonicalRef.where(canonical_work_id: canonical_work.id).maximum(:ord) || 0) + 1
      ref = CanonicalRef.new(
        canonical_work: canonical_work,
        ord: next_ord,
        hierarchy: hierarchy,
        display_label: "#{canonical_work.title} #{chapter}:#{verse_n}#{part_suffix}",
        osis_id: canonical_work.osis_book_id && "#{canonical_work.osis_book_id}.#{chapter}.#{verse_n}#{part_suffix}"
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
      f = File.join(@dir, TEXT_PATH)
      File.exist?(f) ? File.mtime(f).utc.iso8601 : nil
    end
  end
end
