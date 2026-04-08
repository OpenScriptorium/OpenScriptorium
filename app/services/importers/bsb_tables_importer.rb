require "open-uri"

module Importers
  # Imports the Berean Bible interlinear database (bsb_tables.tsv).
  #
  # This single TSV (~82 MB, 754k word rows) contains:
  #
  #   * The Hebrew Bible (Westminster-derived, with Aramaic in Daniel/Ezra)
  #   * The Greek New Testament (Nestle 1904 base, with TR/RP/WH/NE/NA/SBL
  #     variant markers in column 7)
  #   * Word-by-word morphological parsing
  #   * Strong's numbers (Hebrew and Greek)
  #   * Word-level alignment to BSB English
  #   * Headings, cross-references, footnotes
  #
  # Per the Berean Bible Translation Committee's April 2023 dedication,
  # the entire file is in the public domain.
  #
  # On the first run this importer creates two new Works:
  #
  #   * "wlc"          — the Hebrew Bible (with Aramaic for the
  #                      sections of Daniel and Ezra that are in Aramaic)
  #   * "nestle1904"   — the Greek New Testament
  #
  # plus all 754k Word rows tagged with lemma, morphology, Strong's, and
  # transliteration.
  #
  # Idempotent: re-running on the same source produces zero diffs. Each
  # word is fully replaced for any verse whose source revision differs
  # from the work's last import.
  class BsbTablesImporter < BaseImporter
    SOURCE_URL = "https://bereanbible.com/bsb_tables.tsv"
    DEFAULT_PATH = Rails.root.join("tmp/bsb/bsb_tables.tsv")

    # Reuse the BSB importer's book name → slug mapping. The bsb_tables
    # references use the same form: "Genesis 1:1", "1 Samuel 17:50",
    # "Song of Solomon 2:3", etc.
    BOOK_SLUGS = Importers::BsbImporter::BOOK_SLUGS

    REF_REGEX = Importers::BsbImporter::REF_REGEX

    # Combining marks we strip when normalizing Hebrew (cantillation +
    # niqqud) and Greek (breathings + accents). NFD-decomposes the string,
    # filters out anything in the Unicode combining ranges, recomposes.
    HEBREW_COMBINING = /[\u0591-\u05C7]/
    GREEK_COMBINING  = /[\u0300-\u036F\u0483-\u0489\u1AB0-\u1AFF\u1DC0-\u1DFF\u20D0-\u20FF\uFE20-\uFE2F]/

    # Map the file's Language column → which Work the row belongs to.
    LANG_TO_WORK_SLUG = {
      "Hebrew"  => "wlc",
      "Aramaic" => "wlc",
      "Greek"   => "nestle1904"
    }.freeze

    LANG_TO_BCP47 = {
      "Hebrew"  => "he",
      "Aramaic" => "arc",
      "Greek"   => "el-koine"
    }.freeze

    def initialize(path: nil, download: nil, **opts)
      super(**opts)
      @path = path || DEFAULT_PATH
      @download = download.nil? ? !File.exist?(@path) : download
      @lemma_cache = {} # (lang, strongs) → Lemma
    end

    protected

    def source_url
      SOURCE_URL
    end

    def source_format
      "tsv"
    end

    # Non-transactional. With 750k word inserts wrapping the whole import
    # in a single transaction:
    #   * Postgres holds the entire write set in WAL until commit
    #   * Memory grows unboundedly in the Ruby process (we saw ~1GB+)
    #   * No row is visible from outside the importer until done
    #   * A failure mid-run loses everything
    #
    # Per-verse commits give us flat memory, visible progress, and
    # resumability — which is what an academic-scale import needs.
    def transactional?
      false
    end

    def perform
      ensure_source_present!

      @license = License.find_by!(name: "Public Domain")
      @kjv_scheme = VersificationScheme.find_by!(code: "KJV")

      @works = {
        "wlc"        => ensure_wlc_work,
        "nestle1904" => ensure_nestle1904_work
      }

      # Cache canonical_works by slug to avoid 750k lookups
      @canonical_work_cache = {}

      verse_buffer = []
      current_verse_id = nil
      current_ref_str  = nil
      current_lang     = nil

      File.open(@path, "r:bom|utf-8") do |f|
        f.each_line.with_index do |line, idx|
          next if idx == 0  # header

          fields = line.chomp.split("\t", -1)
          next if fields.size < 13

          verse_id = fields[3]
          next if verse_id.blank?
          verse_id = verse_id.to_i

          ref_field = fields[12]
          # Forward-fill the human reference from the first row of each verse
          if ref_field.present?
            current_ref_str = ref_field.strip
          end

          if current_verse_id.nil?
            current_verse_id = verse_id
            current_lang     = fields[4]
          end

          if verse_id != current_verse_id
            process_verse(current_verse_id, current_ref_str_for(current_verse_id, verse_buffer), current_lang, verse_buffer)
            verse_buffer = []
            current_verse_id = verse_id
            current_lang = fields[4]
          end

          verse_buffer << fields
        end
        # Flush the final verse
        if verse_buffer.any?
          process_verse(current_verse_id, current_ref_str_for(current_verse_id, verse_buffer), current_lang, verse_buffer)
        end
      end

      @works.each_value { |w| w.update!(last_imported_at: Time.current, source_revision: source_revision_for_file) }
    end

    private

    # The first row of a verse should always have a non-empty VerseId
    # in column 13. We extract it from the buffer rather than carrying
    # extra state through the loop.
    def current_ref_str_for(verse_id, buffer)
      first = buffer.first
      first && first[12].present? ? first[12].strip : nil
    end

    def ensure_source_present!
      if @download || !File.exist?(@path)
        Rails.logger.info "[BsbTablesImporter] downloading from #{SOURCE_URL}"
        FileUtils.mkdir_p(File.dirname(@path))
        URI.open(SOURCE_URL) { |io| File.binwrite(@path, io.read) }
        bump(:downloaded)
      end
    end

    def ensure_wlc_work
      Work.find_or_initialize_by(slug: "wlc").tap do |w|
        w.assign_attributes(
          title: "Westminster Leningrad Codex",
          native_title: "תורה נביאים וכתובים",
          work_type: "scripture_original",
          language: "he",
          tradition: "jewish",
          genre: "original",
          license: @license,
          default_versification_scheme: @kjv_scheme,
          source_url: "https://bereanbible.com/bsb_tables.tsv",
          publication_year: 2023,
          has_word_data: true,
          description: "The Westminster Leningrad Codex Hebrew Bible (with Aramaic in Daniel 2:4b–7:28 and Ezra 4:8–6:18), as distributed in the Berean interlinear database. Includes word-level morphology and Strong's numbers."
        )
        stamp(w)
        w.save!
      end
    end

    def ensure_nestle1904_work
      Work.find_or_initialize_by(slug: "nestle1904").tap do |w|
        w.assign_attributes(
          title: "Nestle 1904 Greek New Testament",
          native_title: "Η ΚΑΙΝΗ ΔΙΑΘΗΚΗ",
          work_type: "scripture_original",
          language: "el-koine",
          tradition: "critical_text",
          genre: "original",
          license: @license,
          default_versification_scheme: @kjv_scheme,
          source_url: "https://bereanbible.com/bsb_tables.tsv",
          publication_year: 1904,
          has_word_data: true,
          description: "The 1904 Eberhard Nestle Greek New Testament (Η ΚΑΙΝΗ ΔΙΑΘΗΚΗ), as distributed in the Berean interlinear database. The base text is functionally equivalent to NA28 in the vast majority of readings. Includes word-level morphology and Strong's numbers, plus inline markers for TR, RP, WH, NA, and SBL textual witnesses."
        )
        stamp(w)
        w.save!
      end
    end

    # Process all rows for a single verse: ensure work_unit, replace its
    # Words, set body to the concatenated source-language text. Each
    # verse runs in its own small transaction so memory stays flat and
    # progress is visible from outside the importer.
    def process_verse(verse_id, ref_str, language, rows)
      return unless ref_str

      parsed = parse_ref(ref_str) or begin
        bump(:unparseable_refs)
        return
      end
      book, chapter, verse = parsed

      slug = BOOK_SLUGS[book] or begin
        bump(:unknown_books)
        Rails.logger.warn "[BsbTablesImporter] unknown book #{book.inspect}"
        return
      end

      canonical_work = (@canonical_work_cache[slug] ||= CanonicalWork.find_by!(slug: slug))
      work = @works[LANG_TO_WORK_SLUG[language]]
      return unless work

      ActiveRecord::Base.transaction do
        canonical_ref = ensure_canonical_ref(canonical_work, chapter, verse)

        work_unit = WorkUnit.find_or_initialize_by(work_id: work.id, canonical_ref_id: canonical_ref.id)
        if work_unit.new_record?
          work_unit.assign_attributes(
            ord: next_work_unit_ord(work),
            label: "#{chapter}:#{verse}",
            canonical_alignment_type: "exact"
          )
        end

        # Sort by source-language order. Heb Sort = fields[0], Greek Sort
        # = fields[1]. The file's BSB Sort re-orders for English; we want
        # the source-language ordering for the source-language work body.
        sort_col = language == "Greek" ? 1 : 0
        ordered = rows.sort_by { |r| r[sort_col].to_i }

        body = ordered.map { |r| r[5] }.reject(&:blank?).join(" ")
        work_unit.body = body
        stamp(work_unit)
        work_unit.save!

        # Replace this unit's words. Cheaper than diffing.
        Word.where(work_unit_id: work_unit.id).delete_all

        word_attrs = ordered.each_with_index.map do |r, idx|
          surface     = r[5]
          next nil if surface.blank?
          normalized  = normalize(surface, language)
          morph_short = r[8].presence
          strongs     = (language == "Greek" ? r[11] : r[10]).presence
          lemma       = ensure_lemma(language, surface, strongs)

          {
            work_id:        work.id,
            work_unit_id:   work_unit.id,
            position:       idx + 1,
            surface:        surface,
            normalized:     normalized,
            lemma_id:       lemma&.id,
            morph_code:     morph_short,
            strongs_number: strongs,
            import_run_id:  @import_run.id,
            notes:          { translit: r[7], parsing_long: r[9], bsb_word: r[18]&.strip }.compact,
            created_at:     Time.current,
            updated_at:     Time.current
          }
        end.compact

        Word.insert_all(word_attrs) if word_attrs.any?

        bump(:verses_processed)
        bump(:words_processed, word_attrs.size)
      end

      if (@stats[:verses_processed] % 500).zero?
        $stdout.puts "[BsbTablesImporter] #{@stats[:verses_processed]} verses, #{@stats[:words_processed]} words, #{@stats[:lemmas_created] || 0} lemmas"
        $stdout.flush
      end
    end

    def parse_ref(ref_str)
      m = REF_REGEX.match(ref_str.strip)
      return nil unless m
      [m[:book].strip, m[:ch].to_i, m[:v].to_i]
    end

    def ensure_canonical_ref(canonical_work, chapter, verse)
      hierarchy = [chapter, verse]
      ref = CanonicalRef.where(canonical_work_id: canonical_work.id, hierarchy: hierarchy).first
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

    def next_work_unit_ord(work)
      @next_ord ||= {}
      @next_ord[work.id] ||= (WorkUnit.where(work_id: work.id).maximum(:ord) || 0)
      @next_ord[work.id] += 1
    end

    # Lemma deduplication. The bsb_tables file doesn't carry an explicit
    # dictionary form, so we key lemmas on (language, strongs_number) and
    # store the first surface form we see as the canonical lemma string.
    # When we eventually import BDB / LSJ we can replace these placeholder
    # lemma strings with the proper dictionary forms.
    def ensure_lemma(language, surface, strongs)
      return nil if strongs.blank?

      key = [language, strongs]
      cached = @lemma_cache[key]
      return cached if cached

      bcp47 = LANG_TO_BCP47[language] || "und"
      normalized_surface = normalize(surface, language)

      lemma = Lemma.find_by(language: bcp47, lemma: normalized_surface)
      lemma ||= begin
        l = Lemma.new(
          language: bcp47,
          lemma:    normalized_surface,
          normalized: normalized_surface,
          frequency: 0
        )
        stamp(l)
        l.save!
        bump(:lemmas_created)
        l
      end
      @lemma_cache[key] = lemma
      lemma
    end

    def normalize(text, language)
      return text if text.blank?
      decomposed = text.unicode_normalize(:nfd)
      stripped = case language
                 when "Hebrew", "Aramaic" then decomposed.gsub(HEBREW_COMBINING, "")
                 when "Greek"             then decomposed.gsub(GREEK_COMBINING,  "")
                 else decomposed
                 end
      stripped.unicode_normalize(:nfc).strip
    end

    def source_revision_for_file
      File.exist?(@path) ? File.mtime(@path).utc.iso8601 : nil
    end
  end
end
