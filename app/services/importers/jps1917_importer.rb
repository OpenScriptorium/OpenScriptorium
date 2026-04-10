require "json"
require "open-uri"
require "uri"

module Importers
  # Imports the Jewish Publication Society 1917 English translation of
  # the Tanakh — "The Holy Scriptures: A New Translation" — alongside
  # its original print footnotes.
  #
  # ## Why this Work matters
  #
  # JPS 1917 is the first English translation of the Hebrew Bible done
  # by Jewish translators for a Jewish readership. Until 1917, every
  # widely-read English Tanakh was a Christian translation, with all
  # the framing choices that implied (capitalising "Lord", inserting
  # references to the New Testament, supersessionist book ordering).
  # The JPS committee — led by Max Margolis with input from Solomon
  # Schechter, Cyrus Adler, and others — set out to give Anglophone
  # Jewish communities a translation that read the Hebrew on its own
  # terms, used the Masoretic Text without Christian-tradition
  # smoothing, and followed the rabbinic Tanakh book order. Hosting it
  # alongside Christian translations is part of the project's
  # commitment to academic consensus over dogmatic bias.
  #
  # ## Sources
  #
  # ### Verse text — Sefaria GCS bulk export
  #
  # https://storage.googleapis.com/sefaria-export/json/Tanakh/.../English/
  #   The Holy Scriptures A New Translation JPS 1917.json
  #
  # Sefaria mirrors a faithful transcription of the 1917 printing
  # originally published by the Open Siddur project. Public domain.
  # Each book is a single JSON file with `text[chapter][verse]` as a
  # 2D array of strings. Verses follow the Masoretic Text versification
  # (titles count as verse 1 in many psalms; Joel has 4 chapters
  # instead of KJV's 3; etc.) — where this differs from KJV, we create
  # a `*-mt` canonical_work just like KjvaImporter creates `*-kjv`
  # variants for divergent apocryphal numbering.
  #
  # ### Footnotes — JPS Press's official 1917 PDF
  #
  # https://jps.org/wp-content/uploads/2015/10/Tanakh1917.pdf
  #
  # JPS Press hosts a free PDF of the 1917 Tanakh on their own
  # website. Underlying text is unambiguously public domain (1917).
  # Footnotes are extracted from this PDF in a second pass and
  # attached to their verses via work_unit_notes. (See
  # `parse_pdf_footnotes!` below — separated from verse-text import
  # so the easy part doesn't depend on the messy part.)
  class Jps1917Importer < BaseImporter
    SEFARIA_BASE = "https://storage.googleapis.com/sefaria-export/json/Tanakh/"
    PDF_URL      = "https://jps.org/wp-content/uploads/2015/10/Tanakh1917.pdf"
    DEFAULT_DIR  = Rails.root.join("tmp/jps")

    # Map JPS book names (Sefaria's category/book path → our canonical
    # slug). The Sefaria English filename is always
    # "The Holy Scriptures A New Translation JPS 1917.json".
    BOOKS = [
      # [sefaria_path,                            canonical_slug, testament]
      ["Torah/Genesis",                           "genesis",       "ot"],
      ["Torah/Exodus",                            "exodus",        "ot"],
      ["Torah/Leviticus",                         "leviticus",     "ot"],
      ["Torah/Numbers",                           "numbers",       "ot"],
      ["Torah/Deuteronomy",                       "deuteronomy",   "ot"],
      ["Prophets/Joshua",                         "joshua",        "ot"],
      ["Prophets/Judges",                         "judges",        "ot"],
      ["Prophets/I Samuel",                       "1-samuel",      "ot"],
      ["Prophets/II Samuel",                      "2-samuel",      "ot"],
      ["Prophets/I Kings",                        "1-kings",       "ot"],
      ["Prophets/II Kings",                       "2-kings",       "ot"],
      ["Prophets/Isaiah",                         "isaiah",        "ot"],
      ["Prophets/Jeremiah",                       "jeremiah",      "ot"],
      ["Prophets/Ezekiel",                        "ezekiel",       "ot"],
      ["Prophets/Hosea",                          "hosea",         "ot"],
      ["Prophets/Joel",                           "joel",          "ot"],
      ["Prophets/Amos",                           "amos",          "ot"],
      ["Prophets/Obadiah",                        "obadiah",       "ot"],
      ["Prophets/Jonah",                          "jonah",         "ot"],
      ["Prophets/Micah",                          "micah",         "ot"],
      ["Prophets/Nahum",                          "nahum",         "ot"],
      ["Prophets/Habakkuk",                       "habakkuk",      "ot"],
      ["Prophets/Zephaniah",                      "zephaniah",     "ot"],
      ["Prophets/Haggai",                         "haggai",        "ot"],
      ["Prophets/Zechariah",                      "zechariah",     "ot"],
      ["Prophets/Malachi",                        "malachi",       "ot"],
      ["Writings/Psalms",                         "psalms",        "ot"],
      ["Writings/Proverbs",                       "proverbs",      "ot"],
      ["Writings/Job",                            "job",           "ot"],
      ["Writings/Song of Songs",                  "song-of-solomon", "ot"],
      ["Writings/Ruth",                           "ruth",          "ot"],
      ["Writings/Lamentations",                   "lamentations",  "ot"],
      ["Writings/Ecclesiastes",                   "ecclesiastes",  "ot"],
      ["Writings/Esther",                         "esther",        "ot"],
      ["Writings/Daniel",                         "daniel",        "ot"],
      ["Writings/Ezra",                           "ezra",          "ot"],
      ["Writings/Nehemiah",                       "nehemiah",      "ot"],
      ["Writings/I Chronicles",                   "1-chronicles",  "ot"],
      ["Writings/II Chronicles",                  "2-chronicles",  "ot"]
    ].freeze

    SEFARIA_FILENAME = "The Holy Scriptures A New Translation JPS 1917.json".freeze

    def initialize(dir: nil, download: nil, **opts)
      super(**opts)
      @dir = dir || DEFAULT_DIR
      @download = download.nil? ? false : download
    end

    protected

    def source_url
      SEFARIA_BASE
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
      @mt_scheme = VersificationScheme.find_by!(code: "MT")
      @work = ensure_work
      @canonical_work_cache = {}

      Rails.logger.info "[Jps1917Importer] importing #{BOOKS.size} books"
      BOOKS.each { |path, slug, testament| import_book(path, slug, testament) }

      Rails.logger.info "[Jps1917Importer] importing footnotes"
      import_footnotes!

      @work.update!(last_imported_at: Time.current,
                    imported_at: @work.imported_at || Time.current,
                    source_revision: source_revision)
    end

    # Reads the notes JSON produced by `script/extract_jps1917_notes.py`
    # and attaches each note to its work_unit. The script writes one
    # entry per note: {book, chapter, verse, anchor, note, note_type}.
    # Verse coordinates are already validated against Sefaria's text
    # so they line up with our imported MT-scheme verses.
    def import_footnotes!
      notes_path = File.join(@dir, "notes.json")
      unless File.exist?(notes_path)
        Rails.logger.warn "[Jps1917Importer] notes.json missing — skipping footnote import"
        return
      end

      notes = JSON.parse(File.read(notes_path))
      Rails.logger.info "[Jps1917Importer] #{notes.size} notes to attach"

      # Wipe any existing notes from this Work to keep the import
      # idempotent (PaperTrail keeps the history).
      WorkUnitNote.joins(:work_unit)
                  .where(work_units: { work_id: @work.id })
                  .delete_all

      notes.each do |note|
        canonical_work = resolve_canonical_work_for_notes(note["book"])
        next unless canonical_work

        work_unit = WorkUnit
                      .joins(:canonical_ref)
                      .where(work_id: @work.id,
                             canonical_refs: { canonical_work_id: canonical_work.id })
                      .where("canonical_refs.hierarchy[1] = ? AND canonical_refs.hierarchy[2] = ?",
                             note["chapter"], note["verse"])
                      .first

        unless work_unit
          bump(:notes_no_work_unit)
          next
        end

        # Position notes by their order in the JSON file (each verse's
        # notes are already in PDF reading order from the extractor).
        position = WorkUnitNote.where(work_unit_id: work_unit.id).count

        wun = WorkUnitNote.new(
          work_unit:        work_unit,
          position_in_unit: position,
          note_type:        note["note_type"],
          anchor_text:      note["anchor"],
          body:             note["note"]
        )
        stamp(wun)
        wun.save!
        bump(:notes_attached)
      end
    end

    # When attaching a footnote, find the canonical_work that the
    # JPS verses for this book were ACTUALLY imported into. Use the
    # cache populated during import_book — that's the source of truth
    # because resolve_canonical_work picks the right one (existing
    # protestant canonical_work if it covers all MT verses, else a
    # newly-created *-mt parallel).
    #
    # This is important because some books have BOTH `genesis` (KJV
    # scheme, full coverage) AND `genesis-mt` (created by other
    # importers). JPS verses go into `genesis`; notes must follow.
    def resolve_canonical_work_for_notes(book_slug)
      cw = @canonical_work_cache[book_slug]
      unless cw
        # Fallback for slugs not seen during import (shouldn't
        # happen but be defensive)
        cw = CanonicalWork.find_by(slug: book_slug)
        cw ||= CanonicalWork.find_by(slug: "#{book_slug}-mt")
      end
      unless cw
        bump(:notes_no_canonical_work)
        Rails.logger.warn "[Jps1917Importer] no canonical_work for note on #{book_slug.inspect}"
      end
      cw
    end

    private

    def ensure_source_files!
      FileUtils.mkdir_p(File.join(@dir, "sefaria"))

      BOOKS.each do |path, _slug, _testament|
        book_name = path.split("/").last
        local_name = "#{book_name.tr(' ', '_')}.json"
        local_path = File.join(@dir, "sefaria", local_name)

        if @download || !File.exist?(local_path)
          url = SEFARIA_BASE + URI.encode_www_form_component(path.split("/")[0]) + "/" +
                URI.encode_www_form_component(book_name) + "/English/" +
                URI.encode_www_form_component(SEFARIA_FILENAME)
          # GCS uses %20 for spaces in path components, not +
          url = url.gsub("+", "%20")
          Rails.logger.info "[Jps1917Importer] downloading #{book_name}"
          URI.open(url) { |io| File.binwrite(local_path, io.read) }
          bump(:downloaded)
        end
      end
    end

    def ensure_work
      Work.find_or_initialize_by(slug: "jps1917").tap do |w|
        w.assign_attributes(
          title: "Jewish Publication Society 1917",
          native_title: "The Holy Scriptures According to the Masoretic Text — A New Translation",
          work_type: "scripture_translation",
          language: "en",
          traditions: ["ש"],
          genre: "translation",
          license: @license,
          default_versification_scheme: @mt_scheme,
          source_url: "https://opensiddur.org/2010/08/tanakh-the-holy-scriptures-a-new-translation-jps-1917/",
          publication_year: 1917,
          has_word_data: false,
          description: "The Jewish Publication Society's 1917 English translation of the Hebrew Bible — the first English Tanakh produced by Jewish translators for a Jewish readership. Edited by Max Margolis with a committee including Solomon Schechter, Cyrus Adler, Joseph Jacobs, and others. Translated from the Masoretic Text following the rabbinic Tanakh book order, with the Christian-tradition Old Testament conventions deliberately set aside. Public domain. Original print footnotes (\"Heb. uncertain\", \"Or, X\", literal renderings) are extracted from the Jewish Publication Society's freely-hosted PDF of the 1917 edition and attached as work_unit_notes."
        )
        stamp(w)
        w.save!
      end
    end

    def import_book(sefaria_path, slug, testament)
      book_name = sefaria_path.split("/").last
      local_name = "#{book_name.tr(' ', '_')}.json"
      data = JSON.parse(File.read(File.join(@dir, "sefaria", local_name)))

      canonical_work = resolve_canonical_work(slug, data, testament)
      unless canonical_work
        bump(:books_no_canonical_work)
        Rails.logger.warn "[Jps1917Importer] no canonical_work for slug=#{slug.inspect}"
        return
      end

      text = data["text"]
      text.each_with_index do |chapter_verses, ch_idx|
        chapter = ch_idx + 1
        chapter_verses.each_with_index do |verse_text, v_idx|
          verse_n = v_idx + 1
          process_verse(canonical_work, chapter, verse_n, verse_text)
        end
      end

      puts "[Jps1917Importer] #{book_name}: #{@stats[:verses_imported]} verses"
      $stdout.flush
    end

    # Same `*-mt` parallel pattern KjvaImporter uses for divergent
    # apocrypha. If JPS verse numbering matches an existing canonical
    # work (most books do, since the MT and KJV agree on most verse
    # boundaries) we use it directly. Otherwise we create a parallel
    # `*-mt` canonical_work tagged with the MT scheme.
    def resolve_canonical_work(slug, data, testament)
      cached = @canonical_work_cache[slug]
      return cached if cached

      existing = CanonicalWork.find_by(slug: slug)

      if existing && verse_coverage_complete?(existing, data)
        return @canonical_work_cache[slug] = existing
      end

      mt_slug = slug.end_with?("-mt") ? slug : "#{slug}-mt"
      cw = CanonicalWork.find_or_initialize_by(slug: mt_slug)
      base_title = (existing&.title || slug.humanize).sub(/\s*\(.*\)\s*\z/, "")
      cw.assign_attributes(
        book_key:             existing&.book_key || slug,
        title:                "#{base_title} (MT)",
        versification_scheme: @mt_scheme,
        testament:            existing&.testament || testament,
        position:             existing&.position,
        sbl_abbreviation:     existing&.sbl_abbreviation,
        citation_format:      existing&.citation_format || "scripture",
        osis_book_id:         existing&.osis_book_id
      )
      stamp(cw)
      cw.save!

      bump(:mt_canonical_works_created)
      Rails.logger.info "[Jps1917Importer] created MT canonical_work #{mt_slug}"

      ord = 0
      data["text"].each_with_index do |chapter_verses, ch_idx|
        chapter = ch_idx + 1
        chapter_verses.each_with_index do |_, v_idx|
          verse_n = v_idx + 1
          ord += 1
          ref = CanonicalRef.find_or_initialize_by(
            canonical_work_id: cw.id,
            hierarchy: [chapter, verse_n]
          )
          if ref.new_record?
            ref.assign_attributes(
              ord:           ord,
              display_label: "#{cw.title} #{chapter}:#{verse_n}",
              osis_id:       cw.osis_book_id && "#{cw.osis_book_id}.#{chapter}.#{verse_n}"
            )
            stamp(ref)
            ref.save!
            bump(:canonical_refs_created)
          end
        end
      end

      @canonical_work_cache[slug] = cw
    end

    def verse_coverage_complete?(canonical_work, data)
      existing = canonical_work.canonical_refs
                               .where("array_length(hierarchy, 1) = 2")
                               .pluck(:hierarchy)
                               .to_set
      data["text"].each_with_index do |chapter_verses, ch_idx|
        chapter = ch_idx + 1
        chapter_verses.each_with_index do |_, v_idx|
          verse_n = v_idx + 1
          return false unless existing.include?([chapter, verse_n])
        end
      end
      true
    end

    def process_verse(canonical_work, chapter, verse_n, text)
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
        work_unit.body = clean_verse_text(text)
        stamp(work_unit)
        work_unit.save!
        bump(:verses_imported)
      end
    end

    # Sefaria's text often contains stray HTML (italics, big-tags from
    # the Hebrew side, footnote spans). For the verse body we want
    # plain text — strip tags and collapse whitespace.
    def clean_verse_text(text)
      text.to_s
          .gsub(/<[^>]+>/, "")
          .gsub(/\s+/, " ")
          .strip
    end

    def next_work_unit_ord
      @next_ord ||= (WorkUnit.where(work_id: @work.id).maximum(:ord) || 0)
      @next_ord += 1
    end

    def source_revision
      f = File.join(@dir, "sefaria", "Genesis.json")
      File.exist?(f) ? File.mtime(f).utc.iso8601 : nil
    end
  end
end
