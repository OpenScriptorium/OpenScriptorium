require "json"
require "open-uri"

module Importers
  # Imports the King James Version (1769 Blayney revision) with the
  # Apocrypha — modern spelling, the standard "KJV" everyone means —
  # plus the original 1611 marginal notes from Calvin George's
  # exhaustive listing.
  #
  # ## Sources
  #
  # ### Main text — scrollmapper KJVA.json
  #
  # https://github.com/scrollmapper/bible_databases (KJVA folder)
  # GPL-licensed, 80 books (39 OT + 14 Apocrypha + 27 NT), 36,819 verses.
  # Single JSON file, ~13.5 MB. Maps cleanly to our existing
  # canonical_refs for the protestant 66; the apocryphal books only
  # import where KJVA's numbering matches an existing canonical_ref
  # (we don't auto-create canonical_refs for apocryphal books — that's
  # a separate decision because KJVA, Rahlfs, and the various LXX
  # recensions disagree on how the deuterocanon is numbered).
  #
  # ### Marginal notes — Calvin George listing
  #
  # https://en.literaturabautista.com/exhaustive-listing-marginal-notes-1611-edition-king-james-bible
  # Calvin George compiled all 7,348 marginal notes from the original
  # 1611 KJV, presented in modernized spelling so they line up with the
  # modern KJV main text. The notes themselves are 1611 PD facts (not
  # copyrightable as a compilation under Feist v. Rural / Tele-Direct).
  # We use them without attribution.
  #
  # The Calvin George format is line-based:
  #   "Genesis 1:4 divided the light from the darkness: Heb. between the
  #    light and between the darkness"
  # Most entries use ": " between anchor and note. A few use "? " when
  # the anchor ends with a question mark, and one uses ", ". The
  # parser handles all three forms.
  #
  # ## Note types
  #
  # Each marginal note's prefix tells us its type:
  #   * Heb. / Gr. / Chal.   → translation (literal source-language reading)
  #   * Or, / or, / Or       → textual    (alternate reading)
  #   * Some                  → textual    ("some manuscripts say X")
  #   * (no prefix)           → explanation
  class KjvaImporter < BaseImporter
    KJVA_URL = "https://raw.githubusercontent.com/scrollmapper/bible_databases/master/sources/en/KJVA/KJVA.json"
    NOTES_URL = "https://en.literaturabautista.com/exhaustive-listing-marginal-notes-1611-edition-king-james-bible"

    DEFAULT_DIR = Rails.root.join("tmp/kjva")

    # Map KJVA's book names (and Calvin George's variant names) to
    # canonical_works.slug. KJVA uses roman numerals for the
    # I/II/III books, Calvin George uses arabic. Both are normalized.
    BOOK_MAP = {
      # Protestant 66
      "Genesis"            => "genesis",
      "Exodus"             => "exodus",
      "Leviticus"          => "leviticus",
      "Numbers"            => "numbers",
      "Deuteronomy"        => "deuteronomy",
      "Joshua"             => "joshua",
      "Judges"             => "judges",
      "Ruth"               => "ruth",
      "I Samuel"           => "1-samuel",
      "1 Samuel"           => "1-samuel",
      "II Samuel"          => "2-samuel",
      "2 Samuel"           => "2-samuel",
      "I Kings"            => "1-kings",
      "1 Kings"            => "1-kings",
      "II Kings"           => "2-kings",
      "2 Kings"            => "2-kings",
      "I Chronicles"       => "1-chronicles",
      "1 Chronicles"       => "1-chronicles",
      "II Chronicles"      => "2-chronicles",
      "2 Chronicles"       => "2-chronicles",
      "Ezra"               => "ezra",
      "Nehemiah"           => "nehemiah",
      "Esther"             => "esther",
      "Job"                => "job",
      "Psalm"              => "psalms",  # Calvin George uses singular
      "Psalms"             => "psalms",
      "Proverbs"           => "proverbs",
      "Ecclesiastes"       => "ecclesiastes",
      "Song of Solomon"    => "song-of-solomon",
      "Isaiah"             => "isaiah",
      "Jeremiah"           => "jeremiah",
      "Lamentations"       => "lamentations",
      "Ezekiel"            => "ezekiel",
      "Daniel"             => "daniel",
      "Hosea"              => "hosea",
      "Joel"               => "joel",
      "Amos"               => "amos",
      "Obadiah"            => "obadiah",
      "Jonah"              => "jonah",
      "Micah"              => "micah",
      "Nahum"              => "nahum",
      "Habakkuk"           => "habakkuk",
      "Zephaniah"          => "zephaniah",
      "Haggai"             => "haggai",
      "Zechariah"          => "zechariah",
      "Malachi"            => "malachi",
      "Matthew"            => "matthew",
      "Mark"               => "mark",
      "Luke"               => "luke",
      "John"               => "john",
      "Acts"               => "acts",
      "Romans"             => "romans",
      "I Corinthians"      => "1-corinthians",
      "1 Corinthians"      => "1-corinthians",
      "II Corinthians"     => "2-corinthians",
      "2 Corinthians"      => "2-corinthians",
      "Galatians"          => "galatians",
      "Ephesians"          => "ephesians",
      "Philippians"        => "philippians",
      "Colossians"         => "colossians",
      "I Thessalonians"    => "1-thessalonians",
      "1 Thessalonians"    => "1-thessalonians",
      "II Thessalonians"   => "2-thessalonians",
      "2 Thessalonians"    => "2-thessalonians",
      "I Timothy"          => "1-timothy",
      "1 Timothy"          => "1-timothy",
      "II Timothy"         => "2-timothy",
      "2 Timothy"          => "2-timothy",
      "Titus"              => "titus",
      "Philemon"           => "philemon",
      "Hebrews"            => "hebrews",
      "James"              => "james",
      "I Peter"            => "1-peter",
      "1 Peter"            => "1-peter",
      "II Peter"           => "2-peter",
      "2 Peter"            => "2-peter",
      "I John"             => "1-john",
      "1 John"             => "1-john",
      "II John"            => "2-john",
      "2 John"             => "2-john",
      "III John"           => "3-john",
      "3 John"             => "3-john",
      "Jude"               => "jude",
      "Revelation"         => "revelation",
      "Revelation of John" => "revelation",

      # Apocrypha (best-effort: imports verses where KJVA's numbering
      # matches an existing canonical_ref, otherwise skips)
      "I Esdras"           => "1-esdras",
      "II Esdras"          => "2-esdras",
      "Tobit"              => "tobit",
      "Judith"             => "judith",
      "Additions to Esther" => "esther-greek",
      "Wisdom"             => "wisdom",
      "Sirach"             => "sirach",
      "Baruch"             => "baruch",
      "Prayer of Azariah"  => "prayer-of-azariah",
      "Susanna"            => "susanna",
      "Bel and the Dragon" => "bel-and-the-dragon",
      "Prayer of Manasses" => "prayer-of-manasseh",
      "I Maccabees"        => "1-maccabees",
      "II Maccabees"       => "2-maccabees"
    }.freeze

    def initialize(dir: nil, download: nil, **opts)
      super(**opts)
      @dir = dir || DEFAULT_DIR
      @download = download.nil? ? false : download
    end

    protected

    def source_url
      KJVA_URL
    end

    def source_format
      "json"
    end

    def transactional?
      false
    end

    def perform
      ensure_source_files!

      @license = License.find_by!(name: "Public Domain")
      @kjv_scheme = VersificationScheme.find_by!(code: "KJV")
      @work = ensure_work
      @canonical_work_cache = {}

      Rails.logger.info "[KjvaImporter] parsing notes"
      @notes_by_ref = parse_notes_file
      Rails.logger.info "[KjvaImporter] parsed #{@notes_by_ref.values.sum(&:size)} notes"

      Rails.logger.info "[KjvaImporter] parsing main text"
      data = JSON.parse(File.read(File.join(@dir, "KJVA.json")))

      data["books"].each do |book_data|
        process_book(book_data)
      end

      @work.update!(last_imported_at: Time.current,
                    imported_at: @work.imported_at || Time.current,
                    source_revision: source_revision)
    end

    private

    def ensure_source_files!
      FileUtils.mkdir_p(@dir)
      kjva_path = File.join(@dir, "KJVA.json")
      notes_path = File.join(@dir, "notes.html")

      if @download || !File.exist?(kjva_path)
        Rails.logger.info "[KjvaImporter] downloading #{KJVA_URL}"
        URI.open(KJVA_URL) { |io| File.binwrite(kjva_path, io.read) }
        bump(:downloaded_kjva)
      end

      if @download || !File.exist?(notes_path)
        Rails.logger.info "[KjvaImporter] downloading #{NOTES_URL}"
        URI.open(NOTES_URL,
                 "User-Agent" => "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Firefox/120.0"
        ) { |io| File.binwrite(notes_path, io.read) }
        bump(:downloaded_notes)
      end
    end

    def ensure_work
      Work.find_or_initialize_by(slug: "kjv").tap do |w|
        w.assign_attributes(
          title: "King James Version (1769 Blayney revision, with Apocrypha)",
          native_title: "The Holy Bible, Conteyning the Old Testament, and the New",
          work_type: "scripture_translation",
          language: "en",
          tradition: "kjv",
          genre: "translation",
          license: @license,
          default_versification_scheme: @kjv_scheme,
          source_url: "https://github.com/scrollmapper/bible_databases",
          publication_year: 1769,
          has_word_data: false,
          description: "The King James Version of the Bible, including the Apocrypha. The 1769 Blayney revision is the standard form of the KJV that almost all modern editions descend from. Originally published in 1611 by command of King James I of England as a fresh translation from the Hebrew, Greek, and Aramaic; revised over the next 150 years to standardize spelling and correct printing errors. This Work also carries the original 1611 marginal notes (alternate readings, literal Hebrew/Greek renderings, and editorial glosses) attached to the verses they refer to. Original 1611 spelling is deferred to a separate forthcoming Work."
        )
        stamp(w)
        w.save!
      end
    end

    # Parse Calvin George's marginal notes file into a hash keyed by
    # [book_slug, chapter, verse], with each value an array of
    # {anchor:, body:, type:} hashes.
    def parse_notes_file
      html = File.read(File.join(@dir, "notes.html"))
      notes = Hash.new { |h, k| h[k] = [] }

      # Each note is wrapped in <p>...</p>. Pull all <p>s and try the
      # primary parser, then the fallback parsers.
      html.scan(/<p[^>]*>(.*?)<\/p>/m).each do |(content)|
        text = clean_html(content.to_s)
        next if text.empty?

        parsed = parse_note_line(text)
        next unless parsed

        slug = BOOK_MAP[parsed[:book]]
        unless slug
          bump(:notes_unknown_book)
          next
        end

        notes[[slug, parsed[:chapter], parsed[:verse]]] << {
          anchor: clean_anchor(parsed[:anchor]),
          body:   parsed[:note].strip,
          type:   classify_note(parsed[:note])
        }
        bump(:notes_parsed)
      end

      notes
    end

    PRIMARY_NOTE_REGEX  = /\A([1-3]?\s?[A-Z][a-zA-Z ]+?)\s+(\d+):(\d+)\s+(.+?):\s+(.+)\z/
    FALLBACK_Q_REGEX    = /\A([1-3]?\s?[A-Z][a-zA-Z ]+?)\s+(\d+):(\d+)\s+(.+?\?)\s+((?:Heb\.|Gr\.|Or,|or,|Chal\.).+)\z/
    FALLBACK_COMMA_REGEX = /\A([1-3]?\s?[A-Z][a-zA-Z ]+?)\s+(\d+):(\d+)\s+(.+?),\s+((?:Heb\.|Gr\.).+)\z/

    def parse_note_line(text)
      m = PRIMARY_NOTE_REGEX.match(text) ||
          FALLBACK_Q_REGEX.match(text) ||
          FALLBACK_COMMA_REGEX.match(text)
      return nil unless m
      {
        book:    m[1].strip,
        chapter: m[2].to_i,
        verse:   m[3].to_i,
        anchor:  m[4],
        note:    m[5]
      }
    end

    def clean_html(s)
      s.gsub(/<[^>]+>/, "")
       .gsub(/&nbsp;/, " ")
       .gsub(/&#8211;/, "–")
       .gsub(/&amp;/, "&")
       .gsub(/&quot;/, '"')
       .gsub(/&#8217;/, "’")
       .gsub(/&#8216;/, "‘")
       .gsub(/\s+/, " ")
       .strip
    end

    def clean_anchor(a)
      a.sub(/\A[–\-]\s*/, "").strip
    end

    def classify_note(note)
      case note.strip
      when /\A(Heb|Gr|Chal)\./ then "translation"
      when /\A(Or,|or,|Or\s)/  then "textual"
      when /\ASome/             then "textual"
      else                          "explanation"
      end
    end

    def process_book(book_data)
      name = book_data["name"]
      slug = BOOK_MAP[name]
      unless slug
        bump(:books_skipped)
        Rails.logger.warn "[KjvaImporter] no book mapping for #{name.inspect}"
        return
      end

      # Resolve which canonical_work to use. For the protestant 66, the
      # existing canonical_work is KJV-scheme already and matches KJVA
      # verse-by-verse. For the apocrypha, the existing canonical_work
      # may have been built from Rahlfs LXX, which uses different
      # numbering. If KJVA's verse counts disagree with the existing
      # canonical_work, we transparently create a parallel `*-kjv`
      # canonical_work tagged with the KJV scheme — same `book_key`,
      # different recension. The parallel reader's "most-coverage-wins"
      # rule then resolves /kjv/tobit/1 to the KJV recension and
      # /rahlfs-lxx/tobit/1 to the LXX recension.
      canonical_work = resolve_canonical_work(slug, book_data)
      unless canonical_work
        bump(:books_no_canonical_work)
        Rails.logger.warn "[KjvaImporter] no canonical_work for slug=#{slug.inspect}"
        return
      end

      book_data["chapters"].each do |chapter_data|
        chapter = chapter_data["chapter"]
        chapter_data["verses"].each do |v|
          process_verse(canonical_work, slug, chapter, v["verse"], v["text"])
        end
      end

      if (@stats[:verses_imported] % 1000).zero? && @stats[:verses_imported] > 0
        puts "[KjvaImporter] #{name}: #{@stats[:verses_imported]} verses, #{@stats[:notes_created]} notes"
        $stdout.flush
      end
    end

    # Returns the canonical_work that this KJVA book should align to.
    # For the protestant 66 the existing slug works directly. For the
    # apocrypha — where Rahlfs/Brenton may have populated canonical_refs
    # with different numbering — we check whether KJVA's expected verse
    # counts match the existing canonical_refs. If not, we create a
    # `*-kjv` sibling canonical_work with the same `book_key`.
    def resolve_canonical_work(slug, book_data)
      cached = @canonical_work_cache[slug]
      return cached if cached

      existing = CanonicalWork.find_by(slug: slug)

      if existing && verse_coverage_complete?(existing, book_data)
        return @canonical_work_cache[slug] = existing
      end

      # Mismatch (or no existing canonical_work): create a `*-kjv`
      # parallel for this recension.
      kjv_slug = slug.end_with?("-kjv") ? slug : "#{slug}-kjv"
      cw = CanonicalWork.find_or_initialize_by(slug: kjv_slug)
      base_title = (existing&.title || slug.humanize).sub(/\s*\(.*\)\s*\z/, "")
      cw.assign_attributes(
        # Use the same book_key as the existing canonical_work so URLs
        # group properly via book_key (eg /kjv/tobit/1 vs /rahlfs-lxx/tobit/1).
        book_key:             existing&.book_key || slug,
        title:                "#{base_title} (KJV)",
        versification_scheme: @kjv_scheme,
        testament:            existing&.testament || infer_testament(slug),
        position:             existing&.position,
        sbl_abbreviation:     existing&.sbl_abbreviation,
        citation_format:      existing&.citation_format || "scripture",
        osis_book_id:         existing&.osis_book_id
      )
      stamp(cw)
      cw.save!

      bump(:kjv_canonical_works_created)
      Rails.logger.info "[KjvaImporter] created KJV canonical_work #{kjv_slug}"

      # Populate canonical_refs for the new canonical_work from KJVA's
      # own structure.
      ord = 0
      book_data["chapters"].each do |chapter_data|
        chapter = chapter_data["chapter"]
        chapter_data["verses"].each do |v|
          ord += 1
          ref = CanonicalRef.find_or_initialize_by(
            canonical_work_id: cw.id,
            hierarchy: [chapter, v["verse"]]
          )
          if ref.new_record?
            ref.assign_attributes(
              ord:           ord,
              display_label: "#{cw.title} #{chapter}:#{v['verse']}",
              osis_id:       cw.osis_book_id && "#{cw.osis_book_id}.#{chapter}.#{v['verse']}"
            )
            stamp(ref)
            ref.save!
            bump(:canonical_refs_created)
          end
        end
      end

      @canonical_work_cache[slug] = cw
    end

    # True if every KJVA verse in this book has a matching
    # canonical_ref in the existing canonical_work. The canonical_work
    # may legitimately contain MORE refs than KJVA (e.g. our Genesis
    # has [32, 33] from a Hebrew title-numbering import alongside the
    # 1533 KJV verses) — that's fine as long as KJVA's set is a subset.
    def verse_coverage_complete?(canonical_work, book_data)
      existing = canonical_work.canonical_refs
                               .where("array_length(hierarchy, 1) = 2")
                               .pluck(:hierarchy)
                               .to_set
      book_data["chapters"].each do |chapter_data|
        ch = chapter_data["chapter"]
        chapter_data["verses"].each do |v|
          return false unless existing.include?([ch, v["verse"]])
        end
      end
      true
    end

    def infer_testament(slug)
      nt_slugs = %w[matthew mark luke john acts romans 1-corinthians 2-corinthians
                    galatians ephesians philippians colossians 1-thessalonians
                    2-thessalonians 1-timothy 2-timothy titus philemon hebrews
                    james 1-peter 2-peter 1-john 2-john 3-john jude revelation]
      apocrypha_slugs = %w[1-esdras 2-esdras tobit judith esther-greek wisdom sirach
                           baruch prayer-of-azariah susanna bel-and-the-dragon
                           prayer-of-manasseh 1-maccabees 2-maccabees]
      return "nt" if nt_slugs.include?(slug)
      return "deuterocanon" if apocrypha_slugs.include?(slug)
      "ot"
    end

    def process_verse(canonical_work, slug, chapter, verse_n, text)
      canonical_ref = CanonicalRef.where(canonical_work_id: canonical_work.id,
                                          hierarchy: [chapter, verse_n]).first
      unless canonical_ref
        bump(:verses_skipped_no_canonical_ref)
        return
      end

      ActiveRecord::Base.transaction do
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

        # Attach any marginal notes for this verse. Note that the
        # `slug` here is the ORIGINAL book slug (e.g. "tobit"), not the
        # `*-kjv` variant — the notes file uses the original name.
        attach_notes(work_unit, slug, chapter, verse_n)

        bump(:verses_imported)
      end
    end

    def attach_notes(work_unit, slug, chapter, verse_n)
      notes = @notes_by_ref[[slug, chapter, verse_n]]
      return if notes.empty?

      # Idempotency: clear existing notes for this work_unit before re-adding
      WorkUnitNote.where(work_unit_id: work_unit.id).delete_all

      notes.each_with_index do |n, idx|
        wun = WorkUnitNote.new(
          work_unit:        work_unit,
          position_in_unit: idx,
          note_type:        n[:type],
          anchor_text:      n[:anchor],
          body:             n[:body]
        )
        stamp(wun)
        wun.save!
        bump(:notes_created)
      end
    end

    def next_work_unit_ord
      @next_ord ||= (WorkUnit.where(work_id: @work.id).maximum(:ord) || 0)
      @next_ord += 1
    end

    def source_revision
      f = File.join(@dir, "KJVA.json")
      File.exist?(f) ? File.mtime(f).utc.iso8601 : nil
    end
  end
end
