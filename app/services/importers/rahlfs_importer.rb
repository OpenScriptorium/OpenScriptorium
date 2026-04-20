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
      "Bel"     => "bel-and-the-dragon",

      # Books with LXX-specific versification or text divergence from
      # the MT/KJV. Each maps to a separate canonical_work tagged with
      # the LXX versification scheme; same book_key as the MT/KJV
      # version so the URL stays clean (/rahlfs-lxx/psalms/9).
      "Ps"      => "psalms-lxx",
      "Jer"     => "jeremiah-lxx",
      "Job"     => "job-lxx",

      # Theodotion variants — alternative Greek translations of
      # Daniel/Bel/Susanna transmitted alongside the Old Greek text
      # in many LXX manuscripts. They have separate canonical_works
      # under distinct slugs but share book_key with their OG version.
      "DanTh"   => "daniel-theodotion",
      "BelTh"   => "bel-and-the-dragon-theodotion",
      "SusTh"   => "susanna-theodotion",

      # Alternative manuscript recensions (Vaticanus B-text for
      # Joshua/Judges, Sinaiticus recension of Tobit). Same book_key
      # as the primary version, distinct slug.
      "JoshB"   => "joshua-vaticanus-b",
      "JudgB"   => "judges-vaticanus-b",
      "TobS"    => "tobit-sinaiticus"
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

      # Pre-load existing work_units for this work to avoid N+1 SELECTs.
      existing_units = WorkUnit.where(work_id: @work.id)
                               .pluck(:canonical_ref_id, :id, :body, :ord)
      @existing_unit_map = {}
      existing_units.each do |cref_id, id, body, ord|
        @existing_unit_map[cref_id] = { id: id, body: body, ord: ord }
      end

      @wu_insert_batch = []
      @wu_update_batch = []

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
          flush_work_unit_inserts!
          flush_work_unit_updates!
          puts "[RahlfsImporter] #{idx + 1}/#{verses.size} verses, processed=#{@stats[:verses_processed]}, skipped=#{@stats[:skipped_unmapped_book] || 0}"
          $stdout.flush
        end
      end

      flush_work_unit_inserts!
      flush_work_unit_updates!

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
          traditions: ["χ-orthodox", "academic"],
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
    # Single-chapter with sub-verse: "Sus 35a"
    REF_SINGLE_PART  = /\A(?<book>.+?)\s+(?<v>\d+)(?<part>[a-z])\z/
    # Prolog/named chapter: "Sir Prolog:1"
    REF_NAMED_CH     = /\A(?<book>.+?)\s+(?<ch>[A-Za-z]+):(?<v>\d+)(?<part>[a-z])?\z/
    # Range: "Dan 5:26-28" or "Bel 15-17"
    REF_RANGE_REGEX  = /\A(?<book>.+?)\s+(?:(?<ch>\d+):)?(?<v1>\d+)[-–](?<v2>\d+)\z/
    # Split versification: "Jer 7:27/28" or "Bel 31/32"
    REF_SPLIT_REGEX  = /\A(?<book>.+?)\s+(?:(?<ch>\d+):)?(?<v1>\d+)\/(?<v2>\d+)\z/
    # Book-only (superscription/title): "PsSol", "EpJer", "Lam", "Dan"
    REF_BOOK_ONLY    = /\A(?<book>[A-Za-z]+)\z/

    # Named chapters mapped to chapter numbers
    NAMED_CHAPTERS = { "Prolog" => 0 }.freeze

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
      elsif (m = REF_NAMED_CH.match(ref_str))
        # Named chapter like "Sir Prolog:1"
        book_code = m[:book]
        chapter   = NAMED_CHAPTERS[m[:ch]] || 0
        verse_n   = m[:v].to_i
        part      = m[:part] ? (m[:part].ord - 'a'.ord + 1) : nil
      elsif (m = REF_SINGLE_PART.match(ref_str))
        # Single-chapter book with sub-verse like "Sus 35a"
        book_code = m[:book]
        chapter   = 1
        verse_n   = m[:v].to_i
        part      = m[:part].ord - 'a'.ord + 1
      elsif (m = REF_SINGLE_REGEX.match(ref_str))
        book_code = m[:book]
        chapter   = 1
        verse_n   = m[:v].to_i
      elsif (m = REF_RANGE_REGEX.match(ref_str))
        # Verse range (e.g., "Dan 5:26-28"): create work_unit at first
        # verse + pericope marking the full range
        book_code = m[:book]
        chapter   = m[:ch]&.to_i || 1
        verse_n   = m[:v1].to_i
        # After creating the main work_unit, also create a pericope for the range
        @pending_range = { book: book_code, chapter: chapter, v1: m[:v1].to_i, v2: m[:v2].to_i }
        bump(:range_refs)
      elsif (m = REF_SPLIT_REGEX.match(ref_str))
        # Split versification (e.g., "Jer 7:27/28"): the text belongs to
        # both verse numbers in different traditions. Create at first and
        # link to second via markup.
        book_code = m[:book]
        chapter   = m[:ch]&.to_i || 1
        verse_n   = m[:v1].to_i
        @pending_split = { book: book_code, chapter: chapter, v1: m[:v1].to_i, v2: m[:v2].to_i }
        bump(:split_refs)
      elsif (m = REF_BOOK_ONLY.match(ref_str))
        # Book-only ref = superscription/title → create as pericope heading
        book_code = m[:book]
        slug = BOOK_MAP[book_code]
        if slug
          create_superscription(slug, start_word_id, end_word_id)
        end
        return
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

      canonical_ref = ensure_canonical_ref(canonical_work,
        part ? [chapter, verse_n, part] : [chapter, verse_n],
        label: part ? "#{chapter}:#{verse_n}#{('a'.ord + part - 1).chr}" : nil)

      existing = @existing_unit_map[canonical_ref.id]
      now = Time.current

      if existing
        # Only update if body actually changed
        if existing[:body] != body
          @wu_update_batch << {
            id: existing[:id],
            work_id: @work.id,
            ord: existing[:ord],
            body: body,
            label: label,
            canonical_alignment_type: "exact",
            markup: {},
            import_run_id: @import_run.id,
            created_at: now,
            updated_at: now
          }
          bump(:verses_updated)
          flush_work_unit_updates! if @wu_update_batch.size >= 2000
        end
      else
        @wu_insert_batch << {
          work_id: @work.id,
          canonical_ref_id: canonical_ref.id,
          ord: next_work_unit_ord,
          label: label,
          body: body,
          canonical_alignment_type: "exact",
          markup: {},
          import_run_id: @import_run.id,
          created_at: now,
          updated_at: now
        }
        flush_work_unit_inserts! if @wu_insert_batch.size >= 2000
      end

      bump(:verses_processed)
      bump(:subverses_processed) if part

      # Handle range refs: create a pericope spanning v1..v2
      if @pending_range
        r = @pending_range
        @pending_range = nil
        start_ref = ensure_canonical_ref(canonical_work, [r[:chapter], r[:v1]])
        end_ref = ensure_canonical_ref(canonical_work, [r[:chapter], r[:v2]])
        if start_ref && end_ref
          Pericope.find_or_create_by!(
            canonical_work_id: canonical_work.id,
            source_dataset: "rahlfs_range",
            name: "#{canonical_work.sbl_abbreviation} #{r[:chapter]}:#{r[:v1]}–#{r[:v2]}"
          ) do |p|
            p.canonical_range = (start_ref.ord..end_ref.ord + 1)
            p.pericope_type = "verse_range"
            p.tradition = "lxx"
            p.sequence_number = start_ref.ord
            p.import_run_id = @import_run.id
          end
        end
      end

      # Handle split refs: store the alternate verse number in the
      # work_unit markup. Don't duplicate the text — the reader can
      # display "also numbered as 7:28" from the markup.
      if @pending_split
        s = @pending_split
        @pending_split = nil
        # Ensure the alt canonical_ref exists for versification mapping
        ensure_canonical_ref(canonical_work, [s[:chapter], s[:v2]])
        # Tag the primary work_unit's markup with the split info
        # (update the batch entry we just queued)
        entry = @wu_insert_batch.last || @wu_update_batch.last
        if entry
          entry[:markup] = (entry[:markup] || {}).merge(
            "also_numbered" => "#{s[:chapter]}:#{s[:v2]}"
          )
        end
        bump(:split_refs_annotated)
      end
    end

    def flush_work_unit_inserts!
      return if @wu_insert_batch.empty?
      WorkUnit.insert_all(@wu_insert_batch)
      @wu_insert_batch = []
    end

    def flush_work_unit_updates!
      return if @wu_update_batch.empty?
      WorkUnit.upsert_all(@wu_update_batch, unique_by: :id)
      @wu_update_batch = []
    end

    # Book-only refs (e.g., "PsSol", "Lam") are superscriptions or
    # book titles. Create them as pericope headings attached to the
    # first canonical_ref of the book.
    def create_superscription(slug, start_word_id, end_word_id)
      canonical_work = (@canonical_work_cache[slug] ||= CanonicalWork.find_by(slug: slug))
      return unless canonical_work

      # Reconstruct text from word data
      text = (start_word_id..end_word_id).map { |id| @words_by_id[id] }.compact.join(" ")
      return if text.blank?

      # Find the first canonical_ref for this book
      first_ref = CanonicalRef.where(canonical_work_id: canonical_work.id).order(:ord).first
      return unless first_ref

      Pericope.find_or_create_by!(
        canonical_work_id: canonical_work.id,
        source_dataset: "rahlfs_superscription",
        name: text.truncate(200)
      ) do |p|
        p.canonical_range = (first_ref.ord...first_ref.ord + 1)
        p.pericope_type = "superscription"
        p.tradition = "lxx"
        p.sequence_number = 0
        p.import_run_id = @import_run.id
      end
      bump(:superscriptions_created)
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
