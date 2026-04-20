module Importers
  # Imports the 1904 Patriarchal Greek New Testament from USFM.
  #
  # Source: eBible.org grcbyz — the Ecumenical Patriarchate's official
  # Greek NT, used by Eastern Orthodox churches worldwide.
  # License: Public domain
  # Language: Ancient Greek (Koine)
  # Coverage: 27 NT books, with Strong's numbers
  #
  # This is distinct from Robinson-Pierpont (a scholarly Byzantine
  # reconstruction) and from Nestle 1904 (a critical/eclectic text).
  # The Patriarchal text is the OFFICIAL text of the Eastern Orthodox
  # liturgy.
  class PatriarchalNtImporter < BaseImporter
    DEFAULT_DIR = Rails.root.join("tmp/patriarchal")

    BOOK_CODE_TO_SLUG = {
      "MAT" => "matthew", "MRK" => "mark", "LUK" => "luke",
      "JHN" => "john", "ACT" => "acts", "ROM" => "romans",
      "1CO" => "1-corinthians", "2CO" => "2-corinthians",
      "GAL" => "galatians", "EPH" => "ephesians",
      "PHP" => "philippians", "COL" => "colossians",
      "1TH" => "1-thessalonians", "2TH" => "2-thessalonians",
      "1TI" => "1-timothy", "2TI" => "2-timothy",
      "TIT" => "titus", "PHM" => "philemon",
      "HEB" => "hebrews", "JAS" => "james",
      "1PE" => "1-peter", "2PE" => "2-peter",
      "1JN" => "1-john", "2JN" => "2-john", "3JN" => "3-john",
      "JUD" => "jude", "REV" => "revelation"
    }.freeze

    STRONGS_WORD_RE = /\\\+?w\s+([^|]+)\|strong="G?(\d+)"\\\+?w\*/

    def initialize(dir: nil, **opts)
      super(**opts)
      @dir = dir || DEFAULT_DIR
    end

    protected

    def source_url
      "https://ebible.org/find/details.php?id=grcbyz"
    end

    def source_format
      "usfm"
    end

    def transactional?
      false
    end

    def perform
      @license = License.find_by!(name: "Public Domain")
      @kjv_scheme = VersificationScheme.find_by!(code: "KJV")
      @work = ensure_work
      @canonical_work_cache = {}
      @lemma_cache = {}

      Word.where(work_id: @work.id).delete_all

      Dir.glob(File.join(@dir, "*.usfm")).sort.each do |path|
        process_file(path)
      end

      @work.update!(has_word_data: true, last_imported_at: Time.current)
    end

    private

    def ensure_work
      Work.find_or_initialize_by(slug: "patriarchal-1904").tap do |w|
        w.assign_attributes(
          title: "Patriarchal Greek New Testament (1904)",
          native_title: "Η Καινή Διαθήκη",
          work_type: "scripture_original",
          language: "el-koine",
          traditions: ["χ-orthodox"],
          genre: "original",
          license: @license,
          default_versification_scheme: @kjv_scheme,
          source_url: "https://ebible.org/find/details.php?id=grcbyz",
          publication_year: 1904,
          has_word_data: true,
          description: "The 1904 Patriarchal Greek New Testament (with 20 corrections from later editions), the official New Testament text of the Ecumenical Patriarchate of Constantinople. Used in Eastern Orthodox liturgy worldwide. Based on the Byzantine textual tradition."
        )
        stamp(w)
        w.save!
      end
    end

    def process_file(path)
      fname = File.basename(path, ".usfm")
      m = fname.match(/\d+-(\w{3})/)
      return unless m
      book_code = m[1]
      slug = BOOK_CODE_TO_SLUG[book_code]
      unless slug
        bump(:books_skipped)
        return
      end

      canonical_work = (@canonical_work_cache[slug] ||= CanonicalWork.find_by(slug: slug))
      return unless canonical_work

      current_chapter = 0
      File.foreach(path, encoding: "utf-8") do |line|
        line = line.chomp
        current_chapter = $1.to_i if line =~ /\\c\s+(\d+)/
        next unless line =~ /\\v\s+(\d+)\s+(.*)/
        verse_n = $1.to_i
        verse_usfm = $2
        process_verse(canonical_work, current_chapter, verse_n, verse_usfm)
      end
      bump(:books_imported)
    end

    def process_verse(canonical_work, chapter, verse_n, usfm)
      canonical_ref = ensure_canonical_ref(canonical_work, [chapter, verse_n])

      # Extract words with Strong's numbers
      words_data = []
      usfm.scan(STRONGS_WORD_RE) do |surface, strongs|
        words_data << { surface: surface.strip, strongs: "G#{strongs}" }
      end

      # Body text: strip USFM markup
      body = usfm.gsub(/\\\+?w\s+([^|]+)\|[^\\]*\\\+?w\*/, '\1')
                  .gsub(/\\[a-z+*]+/i, "")
                  .gsub(/\|[^\\]*/, "")
                  .gsub(/[¶]/, "")
                  .gsub(/\s+/, " ")
                  .strip

      return if body.empty?

      work_unit = WorkUnit.find_or_initialize_by(
        work_id: @work.id, canonical_ref_id: canonical_ref.id
      )
      if work_unit.new_record?
        work_unit.assign_attributes(
          ord: next_work_unit_ord,
          label: "#{chapter}:#{verse_n}",
          canonical_alignment_type: "exact"
        )
      end
      work_unit.body = body
      stamp(work_unit)
      work_unit.save!

      # Create Word records with Strong's + lemmas
      # If no \w-tagged words found, tokenize from body text (no Strong's/lemma
      # but at least surface forms exist for completeness)
      if words_data.empty? && body.present?
        body.split(/\s+/).reject(&:empty?).each do |token|
          clean = token.gsub(/[,.\-;:—·()]+\z/, "").gsub(/\A[,.\-;:—·()]+/, "")
          next if clean.empty?
          words_data << { surface: clean, strongs: nil }
        end
        bump(:verses_tokenized_from_body) if words_data.any?
      end

      if words_data.any?
        now = Time.current
        word_attrs = words_data.each_with_index.map do |wd, idx|
          lemma = wd[:strongs].present? ? ensure_lemma(wd[:surface], wd[:strongs]) : nil
          {
            work_id: @work.id, work_unit_id: work_unit.id,
            position: idx + 1,
            surface: wd[:surface],
            normalized: wd[:surface].unicode_normalize(:nfd).gsub(/[\u0300-\u036F]/, "").unicode_normalize(:nfc).downcase,
            lemma_id: lemma&.id,
            morph_code: nil,
            strongs_number: wd[:strongs],
            import_run_id: @import_run.id,
            notes: {},
            created_at: now, updated_at: now
          }
        end
        Word.insert_all(word_attrs)
        bump(:words_created, word_attrs.size)
      end

      bump(:verses_imported)
    end

    def ensure_lemma(surface, strongs)
      return nil if strongs.blank?
      cached = @lemma_cache[strongs]
      return cached if cached

      # Check existing lemmas from other Greek works
      existing_id = Word.where(strongs_number: strongs).where.not(lemma_id: nil).limit(1).pick(:lemma_id)
      if existing_id
        @lemma_cache[strongs] = Lemma.find(existing_id)
        return @lemma_cache[strongs]
      end

      normalized = surface.unicode_normalize(:nfd).gsub(/[\u0300-\u036F]/, "").unicode_normalize(:nfc).downcase
      l = Lemma.find_or_initialize_by(language: "el-koine", lemma: normalized)
      if l.new_record?
        l.assign_attributes(normalized: normalized, frequency: 0)
        stamp(l)
        l.save!
        bump(:lemmas_created)
      end
      @lemma_cache[strongs] = l
    end

    def next_work_unit_ord
      @next_ord ||= (WorkUnit.where(work_id: @work.id).maximum(:ord) || 0)
      @next_ord += 1
    end
  end
end
