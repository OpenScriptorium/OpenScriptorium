require "json"

module Importers
  # Adds Strong's numbers and lemma links to the existing KJV Work.
  #
  # Source: kaiserlik/kjv on GitHub — KJV text with inline Strong's
  # tags ([H####] for Hebrew, [G####] for Greek) plus a full
  # lexicon.json with transliterations, definitions, and part of
  # speech for each Strong's number.
  #
  # The KJV Work and its work_units must already exist (created by
  # KjvaImporter). This importer adds per-word Word records with
  # Strong's numbers and links them to existing Lemma rows (or
  # creates new ones from the bundled lexicon).
  #
  # KJV text is public domain. Strong's Concordance (1890) is public
  # domain. The kaiserlik/kjv compilation is a web scrape of PD data.
  class KjvStrongsImporter < BaseImporter
    DEFAULT_DIR = Rails.root.join("tmp/kjv_strongs")

    # kaiserlik book codes → our canonical_works.slug
    BOOK_CODE_TO_SLUG = {
      "Gen" => "genesis", "Exo" => "exodus", "Lev" => "leviticus",
      "Num" => "numbers", "Deu" => "deuteronomy", "Jos" => "joshua",
      "Jdg" => "judges", "Rth" => "ruth",
      "1Sa" => "1-samuel", "2Sa" => "2-samuel",
      "1Ki" => "1-kings", "2Ki" => "2-kings",
      "1Ch" => "1-chronicles", "2Ch" => "2-chronicles",
      "Ezr" => "ezra", "Neh" => "nehemiah", "Est" => "esther",
      "Job" => "job", "Psa" => "psalms", "Pro" => "proverbs",
      "Ecc" => "ecclesiastes", "Sng" => "song-of-solomon",
      "Isa" => "isaiah", "Jer" => "jeremiah", "Lam" => "lamentations",
      "Eze" => "ezekiel", "Dan" => "daniel",
      "Hos" => "hosea", "Joe" => "joel", "Amo" => "amos",
      "Oba" => "obadiah", "Jon" => "jonah", "Mic" => "micah",
      "Nah" => "nahum", "Hab" => "habakkuk", "Zep" => "zephaniah",
      "Hag" => "haggai", "Zec" => "zechariah", "Mal" => "malachi",
      "Mat" => "matthew", "Mar" => "mark", "Luk" => "luke",
      "Jhn" => "john", "Act" => "acts", "Rom" => "romans",
      "1Co" => "1-corinthians", "2Co" => "2-corinthians",
      "Gal" => "galatians", "Eph" => "ephesians",
      "Phl" => "philippians", "Col" => "colossians",
      "1Th" => "1-thessalonians", "2Th" => "2-thessalonians",
      "1Ti" => "1-timothy", "2Ti" => "2-timothy",
      "Tit" => "titus", "Phm" => "philemon",
      "Heb" => "hebrews", "Jas" => "james",
      "1Pe" => "1-peter", "2Pe" => "2-peter",
      "1Jo" => "1-john", "2Jo" => "2-john", "3Jo" => "3-john",
      "Jde" => "jude", "Rev" => "revelation"
    }.freeze

    STRONGS_RE = /\[(H|G)(\d+)\]/

    def initialize(dir: nil, **opts)
      super(**opts)
      @dir = dir || DEFAULT_DIR
    end

    protected

    def source_url
      "https://github.com/kaiserlik/kjv"
    end

    def source_format
      "json"
    end

    def transactional?
      false
    end

    def perform
      @kjv_work = Work.find_by!(slug: "kjv")
      @canonical_work_cache = {}
      @lemma_cache = {}

      load_lexicon!

      # Wipe existing KJV Word records for idempotency
      Word.where(work_id: @kjv_work.id).delete_all

      books = JSON.parse(File.read(File.join(@dir, "books.json")))["books"]
      books.each do |entry|
        entry.each do |_name, code|
          process_book(code)
        end
      end

      @kjv_work.update!(has_word_data: true, last_imported_at: Time.current)
    end

    private

    # Red-letter for KJV deferred — the Strong's bridge from BSB gives
    # paragraph-level but not word-level precision. A dedicated KJV
    # red-letter source with quotation marks is needed.

    def load_lexicon!
      path = File.join(@dir, "lexicon.json")
      return unless File.exist?(path)
      @lexicon = JSON.parse(File.read(path))
      Rails.logger.info "[KjvStrongsImporter] loaded lexicon with #{@lexicon.size} entries"
    end

    def process_book(code)
      slug = BOOK_CODE_TO_SLUG[code]
      unless slug
        bump(:books_skipped)
        return
      end

      path = File.join(@dir, "#{code}.json")
      unless File.exist?(path)
        bump(:books_missing_file)
        return
      end

      data = JSON.parse(File.read(path))
      book_data = data[code]
      return unless book_data

      # Find the canonical_work that the KJV actually uses for this book.
      # The KJV importer may create KJV-specific canonical_works (e.g.
      # "matthew-kjv") when verse numbering differs from the seed data.
      canonical_work = @canonical_work_cache[slug] ||= begin
        CanonicalWork
          .joins(canonical_refs: :work_units)
          .where(work_units: { work_id: @kjv_work.id })
          .where(book_key: slug)
          .group("canonical_works.id")
          .order(Arel.sql("COUNT(work_units.id) DESC"))
          .first || CanonicalWork.find_by(slug: slug)
      end
      unless canonical_work
        bump(:books_no_canonical_work)
        return
      end

      book_data.each do |_chapter_key, chapter_verses|
        chapter_verses.each do |verse_key, verse_data|
          parts = verse_key.split("|")
          next unless parts.length == 3
          en_text = verse_data["en"]
          next if en_text.blank?
          process_verse(canonical_work, parts[1].to_i, parts[2].to_i, en_text)
        end
      end

      bump(:books_imported)
      if (@stats[:books_imported] || 0) % 5 == 0
        $stdout.puts "[KjvStrongsImporter] #{@stats[:books_imported]} books, #{@stats[:words_created] || 0} words"
        $stdout.flush
      end
    end

    def process_verse(canonical_work, chapter, verse_n, en_text)
      canonical_ref = CanonicalRef.where(
        canonical_work_id: canonical_work.id,
        hierarchy: [chapter, verse_n]
      ).first
      unless canonical_ref
        bump(:verses_no_canonical_ref)
        return
      end

      work_unit = WorkUnit.find_by(work_id: @kjv_work.id, canonical_ref_id: canonical_ref.id)
      unless work_unit
        bump(:verses_no_work_unit)
        return
      end

      # Parse word-Strong's pairs from the inline-tagged text
      word_pairs = parse_strongs_text(en_text)
      return if word_pairs.empty?

      word_attrs = word_pairs.each_with_index.map do |(surface, strongs_list), idx|
        primary_strongs = strongs_list.first
        lemma = primary_strongs ? ensure_lemma(primary_strongs) : nil

        {
          work_id:        @kjv_work.id,
          work_unit_id:   work_unit.id,
          position:       idx + 1,
          surface:        surface,
          normalized:     surface.downcase.gsub(/[^\p{L}\p{N}\u2019'\-]/u, ""),
          lemma_id:       lemma&.id,
          morph_code:     nil,
          strongs_number: strongs_list.any? ? strongs_list.join(",") : nil,
          import_run_id:  @import_run.id,
          notes:          strongs_list.size > 1 ? { all_strongs: strongs_list } : {},
          created_at:     Time.current,
          updated_at:     Time.current
        }
      end

      Word.insert_all(word_attrs) if word_attrs.any?
      bump(:words_created, word_attrs.size)
    end

    # Parse "In the beginning[H7225] God[H430] created[H1254][H853]..."
    # into [["In the beginning", ["H7225"]], ["God", ["H430"]], ...]
    def parse_strongs_text(text)
      parts = text.split(/(\[(?:H|G)\d+\])/)
      words = []
      current_text = ""
      current_strongs = []

      parts.each do |part|
        m = STRONGS_RE.match(part)
        if m
          current_strongs << "#{m[1]}#{m[2]}"
        else
          cleaned = part.gsub(/<\/?em>/, "").strip
          if cleaned.present?
            words << [current_text, current_strongs.dup] if current_text.present?
            current_text = cleaned
            current_strongs = []
          end
        end
      end
      words << [current_text, current_strongs.dup] if current_text.present?
      words
    end

    def ensure_lemma(strongs_num)
      return @lemma_cache[strongs_num] if @lemma_cache.key?(strongs_num)

      # First check if a lemma already exists from BSB tables import
      # (they share the same Strong's number space)
      lang = strongs_num.start_with?("H") ? "he" : "el-koine"
      existing = Word.where(strongs_number: strongs_num).where.not(lemma_id: nil).limit(1).pick(:lemma_id)
      if existing
        @lemma_cache[strongs_num] = Lemma.find(existing)
        return @lemma_cache[strongs_num]
      end

      # Create from lexicon if available
      lex_entry = @lexicon&.dig(strongs_num)
      if lex_entry
        lemma_text = lex_entry["Gk_word"].presence || lex_entry["Hb_word"].presence || strongs_num
        l = Lemma.find_or_initialize_by(language: lang, lemma: lemma_text)
        if l.new_record?
          l.assign_attributes(
            normalized:      lemma_text,
            transliteration: lex_entry["transliteration"],
            primary_gloss:   lex_entry["strongs_def"].to_s[0..200],
            part_of_speech:  lex_entry["part_of_speech"],
            frequency:       0
          )
          stamp(l)
          l.save!
          bump(:lemmas_created)
        end
        @lemma_cache[strongs_num] = l
        return l
      end

      @lemma_cache[strongs_num] = nil
    end
  end
end
