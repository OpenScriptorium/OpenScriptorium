require "csv"
require "open-uri"

module Importers
  # Imports the Robinson-Pierpont Byzantine Textform of the Greek New
  # Testament from the byztxt/byzantine-majority-text GitHub repository.
  #
  # Maurice A. Robinson's edition is unambiguously **public domain** —
  # the repository's README states "All the code and text contained in
  # this folder is in the Public Domain."
  #
  # Two source files per NT book:
  #
  #   * csv-unicode/ccat/no-variants/<BOOK>.csv
  #     Accented Greek text with breathings, punctuation. The clean
  #     Byzantine reading without inline variant markers.
  #     Format: chapter,verse,text
  #
  #   * csv-unicode/strongs/with-parsing/<BOOK>.csv
  #     Lowercased text with Strong's numbers and morphological parsing.
  #     Format: chapter,verse,word strongs {morph} word strongs {morph} ...
  #
  # The importer creates one Work ("rp"), 27 work_units per chapter
  # range, and word-level rows with Strong's numbers and morphology.
  class RobinsonPierpontImporter < BaseImporter
    BASE_URL = "https://raw.githubusercontent.com/byztxt/byzantine-majority-text/master/csv-unicode"
    DEFAULT_DIR = Rails.root.join("tmp/byztxt")

    # Maps the byztxt 3-letter book codes to canonical_works slugs.
    BOOK_FILES = {
      "MAT" => "matthew",
      "MAR" => "mark",
      "LUK" => "luke",
      "JOH" => "john",
      "ACT" => "acts",
      "ROM" => "romans",
      "1CO" => "1-corinthians",
      "2CO" => "2-corinthians",
      "GAL" => "galatians",
      "EPH" => "ephesians",
      "PHP" => "philippians",
      "COL" => "colossians",
      "1TH" => "1-thessalonians",
      "2TH" => "2-thessalonians",
      "1TI" => "1-timothy",
      "2TI" => "2-timothy",
      "TIT" => "titus",
      "PHM" => "philemon",
      "HEB" => "hebrews",
      "JAM" => "james",
      "1PE" => "1-peter",
      "2PE" => "2-peter",
      "1JO" => "1-john",
      "2JO" => "2-john",
      "3JO" => "3-john",
      "JUD" => "jude",
      "REV" => "revelation"
    }.freeze

    GREEK_COMBINING = /[\u0300-\u036F\u0483-\u0489\u1AB0-\u1AFF\u1DC0-\u1DFF\u20D0-\u20FF\uFE20-\uFE2F]/

    def initialize(dir: nil, download: nil, **opts)
      super(**opts)
      @dir = dir || DEFAULT_DIR
      @download = download.nil? ? true : download
      @lemma_cache = {} # strongs → Lemma
    end

    protected

    def source_url
      BASE_URL
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
      @kjv_scheme = VersificationScheme.find_by!(code: "KJV")
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
      @words_insert_batch = []
      @deferred_word_data = []  # [{canonical_ref_id:, word_attrs_template: [...]}, ...]

      BOOK_FILES.each do |code, slug|
        canonical_work = (@canonical_work_cache[slug] ||= CanonicalWork.find_by!(slug: slug))
        process_book(code, canonical_work)
        flush_all_batches!
        puts "[RobinsonPierpontImporter] #{code} (#{slug}) done — #{@stats[:verses_processed]} verses, #{@stats[:words_processed]} words"
        $stdout.flush
      end

      @work.update!(last_imported_at: Time.current,
                    imported_at: @work.imported_at || Time.current,
                    source_revision: source_revision)
    end

    private

    def ensure_source_files!
      FileUtils.mkdir_p(File.join(@dir, "ccat"))
      FileUtils.mkdir_p(File.join(@dir, "strongs"))

      BOOK_FILES.each_key do |code|
        ccat_path    = File.join(@dir, "ccat",    "#{code}.csv")
        strongs_path = File.join(@dir, "strongs", "#{code}.csv")

        if @download || !File.exist?(ccat_path)
          ccat_url = "#{BASE_URL}/ccat/no-variants/#{code}.csv"
          Rails.logger.info "[RobinsonPierpontImporter] downloading #{ccat_url}"
          URI.open(ccat_url) { |io| File.binwrite(ccat_path, io.read) }
          bump(:downloaded_ccat)
        end

        if @download || !File.exist?(strongs_path)
          strongs_url = "#{BASE_URL}/strongs/with-parsing/#{code}.csv"
          Rails.logger.info "[RobinsonPierpontImporter] downloading #{strongs_url}"
          URI.open(strongs_url) { |io| File.binwrite(strongs_path, io.read) }
          bump(:downloaded_strongs)
        end
      end
    end

    def ensure_work
      Work.find_or_initialize_by(slug: "rp").tap do |w|
        w.assign_attributes(
          title: "Robinson-Pierpont Byzantine Textform",
          native_title: "Ἡ Καινὴ Διαθήκη ἐν τῇ ἀρχαίᾳ Ἑλληνικῇ — Βυζαντινός Τύπος",
          work_type: "scripture_original",
          language: "el-koine",
          traditions: ["χ-orthodox"],
          genre: "original",
          license: @license,
          default_versification_scheme: @kjv_scheme,
          source_url: "https://github.com/byztxt/byzantine-majority-text",
          publication_year: 2018,
          has_word_data: true,
          description: "The 2018 Robinson-Pierpont edition of the Greek New Testament in the Byzantine Textform, edited by Dr. Maurice A. Robinson and the late William G. Pierpont. The Byzantine text family represents the form of the Greek NT preserved in the majority of Greek manuscripts copied throughout the medieval period. Released into the public domain by the editor."
        )
        stamp(w)
        w.save!
      end
    end

    def process_book(code, canonical_work)
      ccat_path    = File.join(@dir, "ccat",    "#{code}.csv")
      strongs_path = File.join(@dir, "strongs", "#{code}.csv")

      # Build a lookup of (chapter, verse) → strongs row text
      strongs_index = {}
      CSV.foreach(strongs_path, headers: true) do |row|
        ch = row["chapter"].to_i
        v  = row["verse"].to_i
        strongs_index[[ch, v]] = row["text"]
      end

      CSV.foreach(ccat_path, headers: true) do |row|
        chapter   = row["chapter"].to_i
        verse_n   = row["verse"].to_i
        body_text = row["text"]
        next if body_text.blank?

        process_verse(canonical_work, chapter, verse_n, body_text,
                      strongs_index[[chapter, verse_n]])
      end
    end

    def process_verse(canonical_work, chapter, verse_n, body, strongs_text)
      canonical_ref = CanonicalRef.find_by(
        canonical_work_id: canonical_work.id,
        hierarchy: [chapter, verse_n]
      )
      unless canonical_ref
        # Pericope Adulterae and similar verses may not exist in the
        # canonical layer if BSB skipped them. Create on demand.
        canonical_ref = ensure_canonical_ref(canonical_work, [chapter, verse_n])
      end

      # Strip pilcrow (¶) markers used to mark paragraph breaks; we
      # represent paragraphs via markup later. Keep punctuation.
      clean_body = body.gsub(/\A¶/, "").strip
      now = Time.current

      # Pre-parse word data (needs lemma lookups which we do eagerly).
      parsed_words = nil
      if strongs_text.present?
        parsed_words = parse_strongs_words(strongs_text).each_with_index.map do |(surface, strongs, morph), idx|
          lemma = ensure_lemma(surface, strongs)
          {
            work_id:        @work.id,
            position:       idx + 1,
            surface:        surface,
            normalized:     normalize_greek(surface),
            lemma_id:       lemma&.id,
            morph_code:     morph,
            strongs_number: strongs,
            import_run_id:  @import_run.id,
            notes:          {},
            created_at:     now,
            updated_at:     now
          }
        end
      end

      existing = @existing_unit_map[canonical_ref.id]

      if existing
        # Update body if changed
        if existing[:body] != clean_body
          WorkUnit.where(id: existing[:id]).update_all(
            body: clean_body,
            import_run_id: @import_run.id,
            updated_at: now
          )
        end

        # Re-insert words for existing work_units (delete + batch insert)
        Word.where(work_unit_id: existing[:id]).delete_all
        if parsed_words&.any?
          parsed_words.each { |w| w[:work_unit_id] = existing[:id] }
          @words_insert_batch.concat(parsed_words)
          bump(:words_processed, parsed_words.size)
          flush_words! if @words_insert_batch.size >= 3000
        end
      else
        ord = next_work_unit_ord(@work)
        @wu_insert_batch << {
          work_id: @work.id,
          canonical_ref_id: canonical_ref.id,
          ord: ord,
          label: "#{chapter}:#{verse_n}",
          body: clean_body,
          canonical_alignment_type: "exact",
          markup: {},
          import_run_id: @import_run.id,
          created_at: now,
          updated_at: now
        }

        # Defer words for newly-inserted work_units — we need the WU ID.
        if parsed_words&.any?
          @deferred_word_data << {
            canonical_ref_id: canonical_ref.id,
            word_attrs: parsed_words
          }
          bump(:words_processed, parsed_words.size)
        end

        flush_all_batches! if @wu_insert_batch.size >= 2000
      end

      bump(:verses_processed)
    end

    # Parse `word 976 {N-NSF} word 1078 {N-GSF} ...` into [[word, strongs, morph], ...]
    def parse_strongs_words(text)
      tokens = text.strip.split(/\s+/)
      tokens.each_slice(3).map do |w, s, m|
        next nil if w.nil? || s.nil? || m.nil?
        morph = m.delete("{}")
        [w, s, morph]
      end.compact
    end

    def flush_all_batches!
      flush_work_units_and_deferred_words!
      flush_words!
    end

    def flush_work_units_and_deferred_words!
      return if @wu_insert_batch.empty?

      WorkUnit.insert_all(@wu_insert_batch)

      # Look up the IDs of newly-inserted work_units for deferred words.
      if @deferred_word_data.any?
        cref_ids = @deferred_word_data.map { |d| d[:canonical_ref_id] }
        new_units = WorkUnit.where(work_id: @work.id, canonical_ref_id: cref_ids)
                            .pluck(:canonical_ref_id, :id)
        id_map = new_units.to_h

        @deferred_word_data.each do |deferred|
          wu_id = id_map[deferred[:canonical_ref_id]]
          next unless wu_id
          deferred[:word_attrs].each { |w| w[:work_unit_id] = wu_id }
          @words_insert_batch.concat(deferred[:word_attrs])
        end
        @deferred_word_data = []
      end

      @wu_insert_batch = []
    end

    def flush_words!
      return if @words_insert_batch.empty?
      Word.insert_all(@words_insert_batch)
      @words_insert_batch = []
    end

    def next_work_unit_ord(work)
      @next_ord ||= (WorkUnit.where(work_id: work.id).maximum(:ord) || 0)
      @next_ord += 1
    end

    def ensure_lemma(surface, strongs)
      return nil if strongs.blank?
      key = strongs
      cached = @lemma_cache[key]
      return cached if cached

      normalized = normalize_greek(surface)
      lemma = Lemma.find_by(language: "el-koine", lemma: normalized)
      lemma ||= begin
        l = Lemma.new(
          language: "el-koine",
          lemma:    normalized,
          normalized: normalized,
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

    def normalize_greek(text)
      return text if text.blank?
      text.unicode_normalize(:nfd).gsub(GREEK_COMBINING, "").unicode_normalize(:nfc).strip
    end

    def source_revision
      @source_revision ||= begin
        files = BOOK_FILES.keys.flat_map { |c|
          [File.join(@dir, "ccat", "#{c}.csv"), File.join(@dir, "strongs", "#{c}.csv")]
        }
        existing = files.select { |f| File.exist?(f) }
        existing.empty? ? nil : existing.map { |f| File.mtime(f).to_i }.max.to_s
      end
    end
  end
end
