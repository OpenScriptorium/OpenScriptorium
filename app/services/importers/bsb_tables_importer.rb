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

      # Existing BSB Work created by BsbImporter from bsb.txt. We
      # extend it here with per-word data, alignment to the source
      # languages, footnotes, section headings, and cross-references —
      # all from the same Berean tables file. The BSB Work itself
      # must already exist; this importer doesn't create it.
      @bsb_work = Work.find_by(slug: "bsb")
      tag_bsb_with_pericope_tradition!
      reset_bsb_features!

      # State for the heading scanner — open Pericope rows are flushed
      # when a new heading at the same hierarchy level appears, and
      # again at end-of-import for any still open. Keys are heading
      # class strings ("hdg", "subhdg", "suphdg", "pshdg").
      @open_headings = {}

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

      flush_open_headings!

      @works.each_value { |w| w.update!(last_imported_at: Time.current, source_revision: source_revision_for_file) }
      @bsb_work&.update!(last_imported_at: Time.current, source_revision: source_revision_for_file)
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
          traditions: ["ש"],
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
          traditions: ["academic-old", "χ"],
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
        canonical_ref = ensure_canonical_ref(canonical_work, [chapter, verse])

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
        # Disputed/omitted verses in critical editions have no source text
        # but still get a work_unit for verse-number continuity
        body = "⸂ ⸃" if body.blank?
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

        # BSB-side: this same row set carries the English equivalents
        # in column 19, the section headings in column 14, the
        # footnotes in column 22, and the cross-references in column
        # 15. Process them all here while we still hold the verse's
        # row set in memory.
        process_bsb_side!(canonical_work, canonical_ref, ordered, language) if @bsb_work

        bump(:verses_processed)
        bump(:words_processed, word_attrs.size)
      end

      if (@stats[:verses_processed] % 500).zero?
        $stdout.puts "[BsbTablesImporter] #{@stats[:verses_processed]} verses, #{@stats[:words_processed]} words, #{@stats[:lemmas_created] || 0} lemmas"
        $stdout.flush
      end
    end

    # ============================================================
    # BSB-side processing
    # ============================================================
    # The Berean tables file is BSB's own data — every row pairs one
    # source-language word with the English BSB phrase that translates
    # it. Each verse pass below ingests:
    #
    #   * BSB Words — one row per English word (col 19), tagged with
    #     the source-language Strong's of the row it came from.
    #   * AlignmentGroup — one per source row, linking the source
    #     word(s) to the BSB English word(s) on that same row.
    #   * WorkUnitNote — one per row that has a footnote in col 22,
    #     classified by the note text shape ("Cited in" =
    #     cross_reference, "Literally" / "Or" = translation, "MT;
    #     Syriac" / similar = textual).
    #   * Cross-reference rows — col 15 carries an HTML link list
    #     attached to the verse start; we parse the URLs and create
    #     CrossReference rows at the canonical layer (lighting up XRF
    #     for every work that aligns to these refs, not just BSB).
    #   * Section headings — col 14 marks the START of a named
    #     pericope. We track open headings per class and flush them
    #     when a new heading at the same level arrives.
    def process_bsb_side!(canonical_work, canonical_ref, rows, language)
      bsb_unit = WorkUnit.find_by(work_id: @bsb_work.id, canonical_ref_id: canonical_ref.id)
      unless bsb_unit
        # BSB follows the modern critical text (Nestle/UBS), which omits 16
        # verses present in the TR/Byzantine and tagged in bsb_tables.tsv —
        # Matt 17:21, 18:11, 23:14; Mark 7:16, 9:44, 9:46, 11:26, 15:28;
        # Luke 17:36, 23:17; John 5:4; Acts 8:37, 15:34, 24:7, 28:29; Rom
        # 16:24. The tables ship interlinear rows for editorial completeness
        # but BSB has no main-text work_unit for them, so we skip cleanly.
        bump(:bsb_critical_text_omitted)
        return
      end

      # The source-language Words for this verse, in `ordered` row
      # order — the existing process_verse loop just inserted them in
      # exactly that order with position = idx + 1, so we can zip
      # them by index. Look them up once instead of per-row.
      source_unit = WorkUnit
                      .where(canonical_ref_id: canonical_ref.id)
                      .where(work_id: @works.values.map(&:id))
                      .first
      source_words_by_position = if source_unit
        Word.where(work_unit_id: source_unit.id).order(:position).pluck(:position, :id).to_h
      else
        {}
      end

      # 0) Extract paragraph + red-letter markup from the verse's rows.
      #    Col 16 = "Par" (paragraph marker, non-empty on first word of
      #    a new paragraph). Col 18 = "begQ" (beginning of a quotation
      #    — red-letter / OT-in-NT marker). Col 21 = "endQ" (end of
      #    quotation). We store these in the work_unit's markup JSONB
      #    so the reader can render paragraph breaks and red-letter text.
      has_paragraph = rows.any? { |r| r[15].to_s.strip.present? }
      red_letter_words = []
      in_quote = false
      bsb_sort_idx = 0
      rows.sort_by { |r| r[2].to_i }.each do |r|
        phrase = (r[18] || "").strip
        next if phrase.empty? || phrase == "-"
        if r[17].to_s.strip.present?  # begQ
          in_quote = true
        end
        if in_quote
          phrase.split(/\s+/).each do |_tok|
            bsb_sort_idx += 1
            red_letter_words << bsb_sort_idx
          end
        else
          bsb_sort_idx += phrase.split(/\s+/).size
        end
        if r[20].to_s.strip.present?  # endQ
          in_quote = false
        end
      end

      markup = bsb_unit.markup || {}
      markup["paragraph"] = true if has_paragraph
      markup["red_letter_positions"] = red_letter_words if red_letter_words.any?
      if markup != (bsb_unit.markup || {})
        bsb_unit.update_column(:markup, markup)
      end

      # 1) Collect all BSB words + alignment data for this verse, then
      #    flush in 3 batch inserts instead of ~100 individual creates.
      now = Time.current
      all_bsb_word_attrs = []
      alignment_plan = []
      bsb_word_position = 1

      rows.each_with_index do |r, row_idx|
        # Footnotes first (independent of English phrase)
        if (fn_html = r[21].presence)
          create_bsb_footnote(bsb_unit, fn_html, (r[18] || "").strip, row_idx)
        end

        english_phrase = (r[18] || "").strip
        next if english_phrase.empty?
        next if english_phrase == "-"

        tokens = english_phrase.split(/\s+/).reject(&:empty?)
        next if tokens.empty?

        # Pick the column for *this verse's* language. The original code
        # tried r[10] (Hebrew col) first and only fell back to r[11]
        # (Greek col) — for NT rows where Hebrew col is non-empty (rare
        # but it happens in the BSB tables file), this picked H#### and
        # routed the lookup to wlc, returning a Hebrew lemma for English
        # words from a Greek-source NT verse (e.g. James 1:1 "James" →
        # H2385 חֲזִיז instead of G2385 Ἰάκωβος).
        source_strongs = (language == "Greek" ? r[11] : r[10]).presence
        source_lemma   = source_strongs.present? ? lookup_lemma_for_strongs(language, source_strongs) : nil

        first_position = bsb_word_position
        tokens.each do |tok|
          all_bsb_word_attrs << {
            work_id:        @bsb_work.id,
            work_unit_id:   bsb_unit.id,
            position:       bsb_word_position,
            surface:        tok,
            normalized:     tok.downcase.gsub(/[^\p{L}\p{N}\u2019'\-]/u, ""),
            lemma_id:       source_lemma&.id,
            morph_code:     nil,
            strongs_number: source_strongs,
            import_run_id:  @import_run.id,
            notes:          { source_word: r[5], translit: r[7] }.compact,
            created_at:     now,
            updated_at:     now
          }
          bsb_word_position += 1
        end

        src_word_id = source_words_by_position[row_idx + 1]
        if src_word_id
          alignment_plan << {
            first_position: first_position,
            token_count:    tokens.size,
            src_word_id:    src_word_id
          }
        end
      end

      # Flush all BSB words in one insert
      if all_bsb_word_attrs.any?
        bsb_inserted = Word.insert_all(all_bsb_word_attrs, returning: %w[id position]).rows
        bsb_pos_to_id = bsb_inserted.each_with_object({}) { |(id, pos), h| h[pos] = id }
      else
        bsb_pos_to_id = {}
      end

      # Flush all alignment groups in one insert
      if alignment_plan.any? && source_unit
        ag_attrs = alignment_plan.map do |plan|
          {
            canonical_ref_id: canonical_ref.id,
            source_work_id:   source_unit.work_id,
            target_work_id:   @bsb_work.id,
            alignment_type:   "literal",
            confidence:       1.0,
            import_run_id:    @import_run.id,
            created_at:       now,
            updated_at:       now
          }
        end

        ag_ids = AlignmentGroup.insert_all(ag_attrs, returning: %w[id]).rows.flatten
        bump(:alignment_groups_created, ag_ids.size)

        # Flush all alignment group members in one insert
        all_agm_attrs = []
        alignment_plan.each_with_index do |plan, plan_idx|
          ag_id = ag_ids[plan_idx]

          all_agm_attrs << {
            alignment_group_id: ag_id,
            word_id:            plan[:src_word_id],
            role:               "source",
            position:           0,
            import_run_id:      @import_run.id,
            created_at:         now,
            updated_at:         now
          }

          plan[:token_count].times do |i|
            bsb_word_id = bsb_pos_to_id[plan[:first_position] + i]
            next unless bsb_word_id
            all_agm_attrs << {
              alignment_group_id: ag_id,
              word_id:            bsb_word_id,
              role:               "target",
              position:           i,
              import_run_id:      @import_run.id,
              created_at:         now,
              updated_at:         now
            }
          end
        end

        AlignmentGroupMember.insert_all(all_agm_attrs) if all_agm_attrs.any?
      end

      # 3) Cross-references attached to this verse (col 15 — only the
      #    first row of the verse carries them).
      first_row = rows.first
      if first_row && (xref_html = first_row[14].presence)
        process_bsb_xrefs!(canonical_work, canonical_ref, xref_html)
      end

      # 4) Section headings (col 14 — column index 13). Each row that
      #    opens a new heading flushes any open heading at the same
      #    class level and starts a new one. Final headings flush at
      #    end of import.
      rows.each do |r|
        hdg_html = r[13].to_s
        next if hdg_html.empty?
        scan_heading_html(canonical_work, canonical_ref, hdg_html)
      end
    end

    # ------------------------------------------------------------
    # Idempotency: wipe BSB-side rows for a fresh re-import. Doing
    # this once at the start (rather than per-verse) is dramatically
    # faster on the 80,000-verse re-run path.
    # ------------------------------------------------------------
    def reset_bsb_features!
      return unless @bsb_work
      bsb_unit_ids = WorkUnit.where(work_id: @bsb_work.id).pluck(:id)

      # Delete in foreign-key order:
      #   AlignmentGroupMember → AlignmentGroup → Word
      ag_ids = AlignmentGroup.where(target_work_id: @bsb_work.id).pluck(:id)
      AlignmentGroupMember.where(alignment_group_id: ag_ids).delete_all if ag_ids.any?
      AlignmentGroup.where(id: ag_ids).delete_all if ag_ids.any?
      Word.where(work_id: @bsb_work.id).delete_all

      WorkUnitNote.where(work_unit_id: bsb_unit_ids).delete_all
      Pericope.where(source_dataset: "bsb").delete_all
      CrossReference.where(source_dataset: "bsb_inline").delete_all
      bump(:bsb_features_reset)
    end

    def tag_bsb_with_pericope_tradition!
      return unless @bsb_work
      unless @bsb_work.pericope_traditions.include?("bsb_editorial")
        @bsb_work.pericope_traditions = (@bsb_work.pericope_traditions + ["bsb_editorial"]).uniq
        stamp(@bsb_work)
        @bsb_work.save!
      end
    end

    # Look up the source-language Lemma for a given Strong's number,
    # so BSB English words can carry their source lemma_id.
    def lookup_lemma_for_strongs(lang, strongs)
      key = [lang, strongs]
      return @strongs_lemma_cache[key] if @strongs_lemma_cache&.key?(key)
      @strongs_lemma_cache ||= {}
      bcp47 = LANG_TO_BCP47[lang]
      work_ids = bcp47 == "el-koine" ? [@works["nestle1904"]&.id].compact : [@works["wlc"]&.id].compact
      lemma_id = Word.where(work_id: work_ids, strongs_number: strongs)
                      .where.not(lemma_id: nil)
                      .limit(1).pick(:lemma_id)
      @strongs_lemma_cache[key] = lemma_id ? Lemma.find(lemma_id) : nil
    end

    # ------------------------------------------------------------
    # Footnote classification + insertion
    # ------------------------------------------------------------
    FOOTNOTE_CITATION_RE   = /\ACited in\b/
    FOOTNOTE_LITERAL_RE    = /\A(?:Literally|Lit\.)\b/
    FOOTNOTE_OR_RE         = /\AOr\b/
    FOOTNOTE_TEXTUAL_RE    = /\A(?:MT|LXX|DSS|Syriac|Vulgate|Samaritan|Targum)\b[;,]/i

    def create_bsb_footnote(bsb_unit, fn_html, english_phrase, row_idx)
      body = strip_html(fn_html).strip
      return if body.empty?

      type = case body
             when FOOTNOTE_CITATION_RE then "cross_reference"
             when FOOTNOTE_LITERAL_RE  then "translation"
             when FOOTNOTE_OR_RE       then "translation"
             when FOOTNOTE_TEXTUAL_RE  then "textual"
             else                          "explanation"
             end

      note = WorkUnitNote.new(
        work_unit_id:    bsb_unit.id,
        position_in_unit: row_idx,
        note_type:       type,
        anchor_text:     english_phrase.strip,
        body:            body,
        import_run_id:   @import_run.id
      )
      note.save!
      bump(:bsb_footnotes_created)
    end

    # ------------------------------------------------------------
    # Cross-reference parsing
    # ------------------------------------------------------------
    # Col 15 looks like:
    #   <br /><span class=|cross|>(<a href =|../john/1.htm|>John 1:1–5</a>; <a href =|../hebrews/11.htm|>Hebrews 11:1–3</a>)</span>
    # The display text is the canonical reference; we re-parse it to
    # find the target canonical_ref. The href is just for the BSB
    # website — we ignore it.
    XREF_LINK_RE = /<a[^>]*>([^<]+)<\/a>/

    def process_bsb_xrefs!(source_cw, source_ref, xref_html)
      links = xref_html.scan(XREF_LINK_RE).flatten
      links.each do |display|
        begin
          parsed = parse_xref_display(display.strip)
          unless parsed
            bump(:bsb_xrefs_unparsed)
            $stdout.puts "[BsbTablesImporter] UNPARSED XREF: #{display.inspect}" if (@stats[:bsb_xrefs_unparsed]) <= 10
            $stdout.flush
            next
          end

          # Book range: "Joshua–Malachi" spans two different canonical_works
          if parsed[:type] == :book_range
            target_slug1 = BOOK_SLUGS[parsed[:book]]
            target_slug2 = BOOK_SLUGS[parsed[:book2]]
            unless target_slug1 && target_slug2
              bump(:bsb_xrefs_unknown_book)
              next
            end
            target_cw1 = (@canonical_work_cache[target_slug1] ||= CanonicalWork.find_by(slug: target_slug1))
            target_cw2 = (@canonical_work_cache[target_slug2] ||= CanonicalWork.find_by(slug: target_slug2))
            next unless target_cw1 && target_cw2

            # Create xref from source to first book's entire range
            first_ord = CanonicalRef.where(canonical_work_id: target_cw1.id).minimum(:ord)
            last_ord  = CanonicalRef.where(canonical_work_id: target_cw2.id).maximum(:ord)
            next unless first_ord && last_ord

            # Store as two separate xrefs (start book and end book) since
            # they're different canonical_works
            [target_cw1, target_cw2].each do |tcw|
              t_start = CanonicalRef.where(canonical_work_id: tcw.id).minimum(:ord)
              t_end   = CanonicalRef.where(canonical_work_id: tcw.id).maximum(:ord)
              next unless t_start && t_end
              CrossReference.create!(
                source_canonical_work_id: source_cw.id,
                source_range:             (source_ref.ord...(source_ref.ord + 1)),
                target_canonical_work_id: tcw.id,
                target_range:             (t_start...(t_end + 1)),
                relationship_type:        "parallels",
                confidence:               1.0,
                source_dataset:           "bsb_inline",
                status:                   "approved",
                notes:                    "Book range: #{display.strip}",
                import_run_id:            @import_run.id
              )
              bump(:bsb_xrefs_created)
            end
            next
          end

          target_slug = BOOK_SLUGS[parsed[:book]]
          unless target_slug
            bump(:bsb_xrefs_unknown_book)
            next
          end
          target_cw = (@canonical_work_cache[target_slug] ||= CanonicalWork.find_by(slug: target_slug))
          next unless target_cw

          target_start = ord_for_hierarchy(target_cw, parsed[:start_ch], parsed[:start_v])
          target_end   = ord_for_hierarchy(target_cw, parsed[:end_ch],   parsed[:end_v])

          # For chapter ranges, clamp end_v to the actual last verse
          if parsed[:type] == :chapter_range && target_end.nil?
            target_end = CanonicalRef.where(canonical_work_id: target_cw.id)
                           .where("hierarchy[1] = ?", parsed[:end_ch])
                           .maximum(:ord)
          end

          unless target_start && target_end
            bump(:bsb_xrefs_no_target_ord)
            next
          end

          # Ensure start <= end (ords may not be monotonic when
          # canonical_refs were created across multiple import phases)
          if target_start > target_end
            target_start, target_end = target_end, target_start
            bump(:bsb_xrefs_range_swapped)
          end

          CrossReference.create!(
            source_canonical_work_id: source_cw.id,
            source_range:             (source_ref.ord...(source_ref.ord + 1)),
            target_canonical_work_id: target_cw.id,
            target_range:             (target_start...(target_end + 1)),
            # BSB's editorial cross-references are general "see also"
            # links — they don't classify whether the relationship is
            # quotation, allusion, fulfillment, etc. "parallels" is
            # the umbrella we use; if a future dataset (e.g. GNT
            # marginal apparatus) tags relationship type explicitly we
            # can map to the more specific terms then.
            relationship_type:        "parallels",
            confidence:               1.0,
            source_dataset:           "bsb_inline",
            status:                   "approved",
            import_run_id:            @import_run.id
          )
          bump(:bsb_xrefs_created)
        end
      end
    end

    # Display formats we accept:
    #   "John 1:1"                 single verse
    #   "John 1:1–5"               same-chapter range (en-dash)
    #   "1 Chronicles 15:29–16:3"  cross-chapter range
    #   "Genesis 4–9"              chapter range (no verses)
    #   "Joshua–Malachi"           book range
    XREF_DISPLAY_RE = /\A
      (?<book>(?:[1-3]\s)?[A-Z][A-Za-z ]+?)\s+
      (?<ch1>\d+):(?<v1>\d+)
      (?:[\u2013\-](?:(?<ch2>\d+):)?(?<v2>\d+))?
    \z/x

    # Chapter-only range: "Genesis 4–9"
    XREF_CHAPTER_RANGE_RE = /\A
      (?<book>(?:[1-3]\s)?[A-Z][A-Za-z ]+?)\s+
      (?<ch1>\d+)[\u2013\-](?<ch2>\d+)
    \z/x

    # Book range: "Joshua–Malachi"
    XREF_BOOK_RANGE_RE = /\A
      (?<book1>(?:[1-3]\s)?[A-Z][A-Za-z ]+?)
      [\u2013\-]
      (?<book2>(?:[1-3]\s)?[A-Z][A-Za-z ]+?)
    \z/x

    def parse_xref_display(s)
      # Verse-level reference
      if (m = XREF_DISPLAY_RE.match(s))
        return {
          type:        :verse,
          book:        m[:book].strip,
          start_ch:    m[:ch1].to_i,
          start_v:     m[:v1].to_i,
          end_ch:      (m[:ch2] || m[:ch1]).to_i,
          end_v:       (m[:v2] || m[:v1]).to_i
        }
      end

      # Chapter range: "Genesis 4–9" → first verse of ch4 to last verse of ch9
      if (m = XREF_CHAPTER_RANGE_RE.match(s))
        return {
          type:        :chapter_range,
          book:        m[:book].strip,
          start_ch:    m[:ch1].to_i,
          start_v:     1,
          end_ch:      m[:ch2].to_i,
          end_v:       999  # sentinel — will be clamped to last verse
        }
      end

      # Book range: "Joshua–Malachi" → first verse of book1 to last verse of book2
      if (m = XREF_BOOK_RANGE_RE.match(s))
        return {
          type:        :book_range,
          book:        m[:book1].strip,
          book2:       m[:book2].strip,
          start_ch:    1,
          start_v:     1,
          end_ch:      999,
          end_v:       999
        }
      end

      nil
    end

    def ord_for_hierarchy(canonical_work, chapter, verse)
      CanonicalRef
        .where(canonical_work_id: canonical_work.id, hierarchy: [chapter, verse])
        .pick(:ord)
    end

    # ------------------------------------------------------------
    # Heading scanner / pericope creation
    # ------------------------------------------------------------
    HEADING_TAG_RE = /<p\s+class=\|(?<cls>[a-z]+)\|>(?<text>[^<]*)/

    HEADING_TYPE_FOR_CLASS = {
      "suphdg" => "section",
      "hdg"    => "pericope",
      "pshdg"  => "pericope",
      "subhdg" => "heading"
    }.freeze

    def scan_heading_html(canonical_work, canonical_ref, html)
      html.scan(HEADING_TAG_RE) do |cls, text|
        type = HEADING_TYPE_FOR_CLASS[cls] or next
        text = text.strip
        next if text.empty?

        # Flush any open heading of the SAME class — its range ends
        # one ord before this new one starts (i.e. it covered up to
        # the previous verse).
        if (open = @open_headings[cls])
          flush_heading!(open, canonical_ref.ord)
        end

        @open_headings[cls] = {
          canonical_work_id: canonical_work.id,
          name:              text,
          pericope_type:     type,
          source_class:      cls,
          start_ord:         canonical_ref.ord,
          sequence_number:   (@stats[:bsb_pericopes_started] || 0) + 1
        }
        bump(:bsb_pericopes_started)
      end
    end

    def flush_heading!(open, next_start_ord)
      end_ord = next_start_ord - 1
      return if end_ord < open[:start_ord]

      Pericope.create!(
        canonical_work_id: open[:canonical_work_id],
        source_dataset:    "bsb",
        tradition:         "bsb_editorial",
        name:              open[:name],
        pericope_type:     open[:pericope_type],
        sequence_number:   open[:sequence_number],
        canonical_range:   (open[:start_ord]...(end_ord + 1)),
        description:       "BSB section heading (#{open[:source_class]})",
        import_run_id:     @import_run.id
      )
      bump(:bsb_pericopes_created)
    end

    def flush_open_headings!
      @open_headings.each_value do |open|
        # Final flush — extend to the last canonical_ref of the book.
        last_ord = CanonicalRef.where(canonical_work_id: open[:canonical_work_id]).maximum(:ord)
        next unless last_ord
        flush_heading!(open, last_ord + 1)
      end
      @open_headings = {}
    end

    # ------------------------------------------------------------
    # Misc helpers
    # ------------------------------------------------------------
    def source_unit_id_to_work_id(unit_id)
      @unit_to_work ||= {}
      @unit_to_work[unit_id] ||= WorkUnit.where(id: unit_id).pick(:work_id)
    end

    def strip_html(s)
      s.to_s.gsub(/<[^>]+>/, "").gsub("&nbsp;", " ").gsub("&amp;", "&").gsub(/\s+/, " ").strip
    end

    def parse_ref(ref_str)
      m = REF_REGEX.match(ref_str.strip)
      return nil unless m
      [m[:book].strip, m[:ch].to_i, m[:v].to_i]
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

      # Prefer an existing DICTIONARY lemma keyed off this Strong's number
      # over creating a new surface-form stub. Without this, every inflected
      # form in the BSB tables (αἰτοῦντι, ἠγαπημένος, …) becomes its own
      # lemma row with no metadata, and we end up with thousands of stubs
      # that have to be consolidated later.
      lemma = find_lemma_by_strongs(strongs, language)
      if lemma
        @lemma_cache[key] = lemma
        bump(:lemmas_resolved_by_strongs)
        return lemma
      end

      # Fallback: no corpus word has this Strong's yet. Match by surface
      # within the same language, or create a new lemma. This path runs
      # rarely once the rest of the corpus is loaded.
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
