require "nokogiri"
require "open-uri"

module Importers
  # Imports the Lutherbibel 1912 (German), public domain by age.
  #
  # ## Source
  #
  # Karl-Barth/luther-bibel TEI XML on GitHub:
  # https://github.com/Karl-Barth/luther-bibel
  #
  # A clean, hand-curated TEI transcription. 67 books (Protestant 66 +
  # Tobit, the latter sourced separately from die-bibel.de). 31,175
  # verses. No annotation apparatus — the 1912 was a textual revision
  # without footnotes; we ship it as plain text. Modern German spelling
  # post-1901 orthographic reform.
  #
  # ## Note on the apocrypha
  #
  # The XML includes only Tobit (n=68), which is from a different source
  # and is the only deuterocanonical book present. We import the
  # protestant 66 from the main TEI body and skip Tobit — when we ship a
  # full Luther apocrypha later it will come from a single coherent
  # source rather than this one orphaned book.
  class Luther1912Importer < BaseImporter
    SOURCE_URL = "https://raw.githubusercontent.com/Karl-Barth/luther-bibel/master/luther-bibel.xml"
    DEFAULT_DIR = Rails.root.join("tmp/luther")

    # Luther's TEI book ids → our canonical_works.slug. The numbered
    # books use IDs like "1.Sam", "2.Kön", "1.Petr".
    BOOK_MAP = {
      "Gen"     => "genesis",
      "Ex"      => "exodus",
      "Lev"     => "leviticus",
      "Num"     => "numbers",
      "Dtn"     => "deuteronomy",
      "Jos"     => "joshua",
      "Ri"      => "judges",
      "Rut"     => "ruth",
      "1.Sam"   => "1-samuel",
      "2.Sam"   => "2-samuel",
      "1.Kön"   => "1-kings",
      "2.Kön"   => "2-kings",
      "1.Chr"   => "1-chronicles",
      "2.Chr"   => "2-chronicles",
      "Esra"    => "ezra",
      "Neh"     => "nehemiah",
      "Esth"    => "esther",
      "Hiob"    => "job",
      "Ps"      => "psalms",
      "Spr"     => "proverbs",
      "Pred"    => "ecclesiastes",
      "Hld"     => "song-of-solomon",
      "Jes"     => "isaiah",
      "Jer"     => "jeremiah",
      "Klagel"  => "lamentations",
      "Hes"     => "ezekiel",
      "Dan"     => "daniel",
      "Hos"     => "hosea",
      "Joel"    => "joel",
      "Am"      => "amos",
      "Ob"      => "obadiah",
      "Jona"    => "jonah",
      "Mi"      => "micah",
      "Nah"     => "nahum",
      "Hab"     => "habakkuk",
      "Zeph"    => "zephaniah",
      "Hag"     => "haggai",
      "Sach"    => "zechariah",
      "Mal"     => "malachi",
      "Mt"      => "matthew",
      "Mk"      => "mark",
      "Lk"      => "luke",
      "Joh"     => "john",
      "Act"     => "acts",
      "Röm"     => "romans",
      "1.Kor"   => "1-corinthians",
      "2.Kor"   => "2-corinthians",
      "Gal"     => "galatians",
      "Eph"     => "ephesians",
      "Phil"    => "philippians",
      "Kol"     => "colossians",
      "1.Thess" => "1-thessalonians",
      "2.Thess" => "2-thessalonians",
      "1.Tim"   => "1-timothy",
      "2.Tim"   => "2-timothy",
      "Tit"     => "titus",
      "Phlm"    => "philemon",
      "Hebr"    => "hebrews",
      "Jak"     => "james",
      "1.Petr"  => "1-peter",
      "2.Petr"  => "2-peter",
      "1.Joh"   => "1-john",
      "2.Joh"   => "2-john",
      "3.Joh"   => "3-john",
      "Jud"     => "jude",
      "Apk"     => "revelation"
    }.freeze

    # Books where Luther 1912 has its own verse structure that doesn't
    # match either KJV or our existing MT canonical_works. For these we
    # build (and own) a German-scheme canonical_work cloned from
    # Luther's TEI structure, and route ALL of Luther's verses for the
    # book through it. The German→KJV verse mappings live in
    # versification_mappings, populated by the TVTMS importer (upstream
    # German rows + db/data/tvtms_openscriptorium_overlay.tsv).
    #
    # Other divergent OT books (Job, Nehemiah, Jeremiah, etc.) continue
    # to route through their `*-mt` canonical_works because Luther's
    # German tradition genuinely follows the Hebrew Masoretic versification
    # for those books — psalms is the major exception where the German
    # title-as-v1 convention requires its own modeling, and 3 John /
    # Revelation are NT-specific Lutheran splits.
    GERMAN_DIVERGENT_BOOKS = {
      "psalms"     => "psalms-german",
      "3-john"     => "3-john-german",
      "revelation" => "revelation-german"
    }.freeze

    def initialize(dir: nil, download: nil, **opts)
      super(**opts)
      @dir = dir || DEFAULT_DIR
      @download = download.nil? ? false : download
    end

    protected

    def source_url
      SOURCE_URL
    end

    def source_format
      "xml"
    end

    def transactional?
      false
    end

    def perform
      ensure_source_file!

      @license = License.find_by!(name: "Public Domain")
      @kjv_scheme    = VersificationScheme.find_by!(code: "KJV")
      @german_scheme = VersificationScheme.find_by!(code: "German")
      @work = ensure_work

      Rails.logger.info "[Luther1912Importer] parsing TEI"
      doc = Nokogiri::XML(File.read(xml_path))
      doc.remove_namespaces!

      doc.xpath("//div[@type='book']").each do |book_div|
        process_book(book_div)
      end

      @work.update!(last_imported_at: Time.current,
                    imported_at: @work.imported_at || Time.current,
                    source_revision: source_revision)
    end

    private

    def xml_path
      File.join(@dir, "luther-bibel.xml")
    end

    def ensure_source_file!
      FileUtils.mkdir_p(@dir)
      return if File.exist?(xml_path) && !@download

      Rails.logger.info "[Luther1912Importer] downloading #{SOURCE_URL}"
      URI.open(SOURCE_URL) { |io| File.binwrite(xml_path, io.read) }
      bump(:downloaded)
    end

    def ensure_work
      Work.find_or_initialize_by(slug: "luther-1912").tap do |w|
        w.assign_attributes(
          title: "Lutherbibel 1912",
          native_title: "Die Bibel oder die ganze Heilige Schrift des Alten und Neuen Testaments nach der Übersetzung Martin Luthers",
          work_type: "scripture_translation",
          language: "de",
          tradition: "luther",
          genre: "translation",
          license: @license,
          default_versification_scheme: @kjv_scheme,
          source_url: "https://github.com/Karl-Barth/luther-bibel",
          publication_year: 1912,
          has_word_data: false,
          description: "The 1912 revision of Martin Luther's German Bible. Luther's first complete translation appeared in 1534, with his final personally-supervised edition in 1545. Subsequent revisions modernized the orthography and corrected printing errors while preserving Luther's distinctive renderings; the 1912 revision was the first to follow the 1901 German orthographic reform and remained the standard German Protestant Bible until the 1984 revision. This edition has no annotation apparatus — the 1912 revisers stripped Luther's marginalia, and a transcription of the 1545 marginalia in modern spelling does not yet exist in any free digital format."
        )
        stamp(w)
        w.save!
      end
    end

    def process_book(book_div)
      raw_id = book_div["id"] # nokogiri strips xml: prefix after remove_namespaces!
      tei_book = raw_id.to_s.sub(/\ALb_/, "")
      slug = BOOK_MAP[tei_book]
      unless slug
        bump(:books_skipped)
        Rails.logger.info "[Luther1912Importer] skipping book id=#{tei_book.inspect}"
        return
      end

      german_slug = GERMAN_DIVERGENT_BOOKS[slug]
      if german_slug
        # Luther owns this book's verse structure. Build (or reuse) a
        # German canonical_work cloned from the TEI structure and route
        # ALL of Luther's verses through it. Older work_units that
        # might have been created against the KJV-scheme canonical_work
        # by an earlier import run get cleaned up first.
        canonical_work = ensure_german_canonical_work(slug, german_slug, book_div)
        cleanup_legacy_work_units!(slug)
        mt_fallback = nil
      else
        canonical_work = CanonicalWork.find_by(slug: slug)
        unless canonical_work
          bump(:books_no_canonical_work)
          Rails.logger.warn "[Luther1912Importer] no canonical_work for slug=#{slug.inspect}"
          return
        end
        # For other OT divergent books (Job, Nehemiah, Jeremiah, etc.)
        # Luther's tradition follows the Hebrew Masoretic versification
        # — fall back to the existing `*-mt` canonical_work for any
        # verse that doesn't exist in the KJV scheme.
        mt_fallback = CanonicalWork.find_by(slug: "#{slug}-mt")
      end

      book_div.xpath(".//ab").each do |ab|
        ab_id = ab["id"].to_s
        m = ab_id.match(/\.(\d+)\.(\d+)\z/)
        next unless m
        chapter = m[1].to_i
        verse_n = m[2].to_i
        text = normalize_text(ab.text)
        next if text.empty?
        process_verse(canonical_work, mt_fallback, chapter, verse_n, text)
      end

      if (@stats[:verses_imported] % 2000).zero? && @stats[:verses_imported] > 0
        puts "[Luther1912Importer] #{slug}: book done, #{@stats[:verses_imported]} verses total"
        $stdout.flush
      end
      bump(:books_imported)
    end

    # Build (or refresh) the `*-german` canonical_work for a book where
    # Luther 1912's verse structure differs from both KJV and our
    # existing `*-mt` schemes. The canonical_refs are cloned directly
    # from Luther's TEI structure for this book — Luther is the
    # authoritative source for German verse boundaries here.
    def ensure_german_canonical_work(base_slug, german_slug, book_div)
      base_cw = CanonicalWork.find_by(slug: base_slug)

      cw = CanonicalWork.find_or_initialize_by(slug: german_slug)
      cw.assign_attributes(
        book_key:             base_cw&.book_key || base_slug,
        title:                base_cw ? base_cw.title.sub(/\s*\(.*\)\s*\z/, "") : base_slug.humanize,
        versification_scheme: @german_scheme,
        testament:            base_cw&.testament,
        position:             base_cw&.position,
        sbl_abbreviation:     base_cw&.sbl_abbreviation,
        citation_format:      base_cw&.citation_format || "scripture",
        osis_book_id:         base_cw&.osis_book_id
      )
      stamp(cw)
      cw.save!
      bump(:german_canonical_works_created) if cw.previous_changes.key?("id")

      # Walk Luther's TEI for this book and ensure a canonical_ref
      # exists for every (chapter, verse) Luther carries. Existing refs
      # are left alone — this is idempotent across reruns.
      ord = (CanonicalRef.where(canonical_work_id: cw.id).maximum(:ord) || 0)
      book_div.xpath(".//ab").each do |ab|
        m = ab["id"].to_s.match(/\.(\d+)\.(\d+)\z/) or next
        ch = m[1].to_i
        v  = m[2].to_i
        ref = CanonicalRef.find_or_initialize_by(canonical_work_id: cw.id, hierarchy: [ch, v])
        next unless ref.new_record?

        ord += 1
        ref.assign_attributes(
          ord:           ord,
          display_label: "#{cw.title} #{ch}:#{v}",
          osis_id:       cw.osis_book_id && "#{cw.osis_book_id}.#{ch}.#{v}"
        )
        stamp(ref)
        ref.save!
        bump(:german_canonical_refs_created)
      end

      cw
    end

    # When a book gets rerouted to its `*-german` canonical_work, any
    # existing Luther work_units that were previously created against
    # the base (KJV-scheme) canonical_work need to be cleared so the
    # rerun produces a clean state. We only delete work_units that
    # belong to THIS work (luther-1912) — other works' alignments to
    # the base canonical_work are untouched.
    def cleanup_legacy_work_units!(base_slug)
      base_cw = CanonicalWork.find_by(slug: base_slug)
      mt_cw   = CanonicalWork.find_by(slug: "#{base_slug}-mt")
      base_ids = [base_cw, mt_cw].compact.map(&:id)
      return if base_ids.empty?
      base_ref_ids = CanonicalRef.where(canonical_work_id: base_ids).pluck(:id)
      n = WorkUnit.where(work_id: @work.id, canonical_ref_id: base_ref_ids).delete_all
      bump(:legacy_work_units_cleared, n) if n > 0
    end

    def normalize_text(s)
      s.to_s.gsub(/\s+/, " ").strip
    end

    def process_verse(canonical_work, mt_fallback, chapter, verse_n, text)
      canonical_ref = CanonicalRef.where(canonical_work_id: canonical_work.id,
                                          hierarchy: [chapter, verse_n]).first
      if canonical_ref.nil? && mt_fallback
        canonical_ref = CanonicalRef.where(canonical_work_id: mt_fallback.id,
                                            hierarchy: [chapter, verse_n]).first
        bump(:verses_via_mt_fallback) if canonical_ref
      end

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
        bump(:verses_imported)
      end
    end

    def next_work_unit_ord
      @next_ord ||= (WorkUnit.where(work_id: @work.id).maximum(:ord) || 0)
      @next_ord += 1
    end

    def source_revision
      File.exist?(xml_path) ? File.mtime(xml_path).utc.iso8601 : nil
    end
  end
end
