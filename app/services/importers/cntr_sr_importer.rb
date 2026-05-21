module Importers
  # Imports the CNTR Statistical Restoration Greek New Testament.
  #
  # Source: Center-for-New-Testament-Restoration/SR on GitHub
  # License: CC BY 4.0
  # Format: TSV with columns: Verse, Modern, Koine, Lemma, ESN, Role, Morphology
  #
  # The SR is a statistically reconstructed Greek NT — the text is
  # computed algorithmically from manuscript evidence rather than by
  # editorial committee. Each word carries a lemma, Enhanced Strong's
  # Number, part-of-speech role, and detailed morphology.
  class CntrSrImporter < BaseImporter
    DEFAULT_PATH = Rails.root.join("tmp/bhp/SR.tsv")

    # OSIS book numbers → our canonical_works.slug
    BOOK_NUM_TO_SLUG = {
      40 => "matthew", 41 => "mark", 42 => "luke", 43 => "john",
      44 => "acts", 45 => "romans",
      46 => "1-corinthians", 47 => "2-corinthians",
      48 => "galatians", 49 => "ephesians", 50 => "philippians",
      51 => "colossians",
      52 => "1-thessalonians", 53 => "2-thessalonians",
      54 => "1-timothy", 55 => "2-timothy",
      56 => "titus", 57 => "philemon",
      58 => "hebrews", 59 => "james",
      60 => "1-peter", 61 => "2-peter",
      62 => "1-john", 63 => "2-john", 64 => "3-john",
      65 => "jude", 66 => "revelation"
    }.freeze

    def initialize(path: nil, **opts)
      super(**opts)
      @path = path || DEFAULT_PATH
    end

    protected

    def source_url
      "https://github.com/Center-for-New-Testament-Restoration/SR"
    end

    def source_format
      "tsv"
    end

    def transactional?
      false
    end

    SOURCE_FILE_URL = "https://raw.githubusercontent.com/Center-for-New-Testament-Restoration/SR/main/SR.tsv".freeze

    def perform
      download_source unless File.exist?(@path)

      @license = License.find_by!(name: "CC BY 4.0") rescue License.find_by!(name: "Public Domain")
      @kjv_scheme = VersificationScheme.find_by!(code: "KJV")
      @work = ensure_work
      @canonical_work_cache = {}
      @lemma_cache = {}

      # Wipe existing words for idempotency
      Word.where(work_id: @work.id).delete_all

      current_verse = nil
      current_words = []

      File.open(@path, "r:bom|utf-8") do |f|
        f.each_line.with_index do |line, idx|
          next if idx == 0  # header
          fields = line.chomp.split("\t", -1)
          next if fields.size < 7

          verse_ref = fields[0]
          if verse_ref != current_verse
            flush_verse!(current_verse, current_words) if current_verse && current_words.any?
            current_verse = verse_ref
            current_words = []
          end
          current_words << fields
        end
      end
      flush_verse!(current_verse, current_words) if current_verse && current_words.any?

      @work.update!(has_word_data: true, last_imported_at: Time.current)
    end

    def download_source
      require "open-uri"
      FileUtils.mkdir_p(File.dirname(@path))
      Rails.logger.info "[CntrSrImporter] downloading #{SOURCE_FILE_URL}"
      File.binwrite(@path, URI.open(SOURCE_FILE_URL).read)
      bump(:source_downloaded)
    end

    private

    def ensure_work
      Work.find_or_initialize_by(slug: "cntr-sr").tap do |w|
        w.assign_attributes(
          title: "CNTR Statistical Restoration",
          native_title: "Η ΚΑΙΝΗ ΔΙΑΘΗΚΗ",
          work_type: "scripture_original",
          language: "el-koine",
          traditions: ["academic", "χ"],
          genre: "original",
          license: @license,
          default_versification_scheme: @kjv_scheme,
          source_url: "https://github.com/Center-for-New-Testament-Restoration/SR",
          publication_year: 2023,
          has_word_data: true,
          description: "The Statistical Restoration Greek New Testament from the Center for New Testament Restoration. Unlike committee-based critical editions (NA28, UBS5), the SR text is computed algorithmically from digitized manuscript evidence, weighting witnesses by age, text-type, and independence. CC BY 4.0."
        )
        stamp(w)
        w.save!
      end
    end

    # Parse "40001001" → [book_num, chapter, verse]
    def parse_verse_ref(ref)
      return nil unless ref =~ /\A(\d{2})(\d{3})(\d{3})\z/
      [$1.to_i, $2.to_i, $3.to_i]
    end

    def flush_verse!(verse_ref, words)
      parsed = parse_verse_ref(verse_ref) or return
      book_num, chapter, verse_n = parsed

      slug = BOOK_NUM_TO_SLUG[book_num] or return
      canonical_work = (@canonical_work_cache[slug] ||= CanonicalWork.find_by(slug: slug))
      return unless canonical_work

      canonical_ref = ensure_canonical_ref(canonical_work, [chapter, verse_n])

      # Create or update work_unit
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
      # Body = modern Greek text (col 1), stripping paragraph marks
      body = words.map { |w| w[1].gsub(/[¶§]/, "").strip }.reject(&:empty?).join(" ")
      work_unit.body = body
      stamp(work_unit)
      work_unit.save!

      # Create Word records
      word_attrs = words.each_with_index.map do |fields, idx|
        surface = fields[1].gsub(/[¶§]/, "").strip
        next nil if surface.empty?
        koine = fields[2]
        lemma_text = fields[3]
        esn = fields[4]  # Enhanced Strong's Number
        role = fields[5]
        morph = fields[6]

        # CNTR encodes Enhanced Strong's as base × 10 + variant digit
        # (variant 0 = the canonical base entry; 1..9 = homonym variants).
        # Storing the raw ESN as `strongs_number` collides with other
        # importers' standard-Strong's storage — e.g., CNTR's "G250"
        # (= ESN for G25 αγαπάω) collides with KJV's "G250" (= standard
        # G250 ἀλόη). Normalize to standard Strong's at storage time and
        # preserve the variant digit in notes for downstream research.
        standard_strongs = nil
        esn_variant = nil
        esn_str = esn.to_s.strip
        if esn_str.match?(/\A\d{2,}\z/)
          base = esn_str[0..-2].to_i
          standard_strongs = "G#{base}" if base.positive?
          esn_variant = esn_str[-1].to_i
        end

        lemma = ensure_lemma(lemma_text, standard_strongs)

        {
          work_id:        @work.id,
          work_unit_id:   work_unit.id,
          position:       idx + 1,
          surface:        surface,
          normalized:     koine.to_s.strip,
          lemma_id:       lemma&.id,
          morph_code:     "#{role}:#{morph}",
          strongs_number: standard_strongs,
          import_run_id:  @import_run.id,
          notes:          { esn: esn_str.presence, esn_variant: esn_variant }.compact,
          created_at:     Time.current,
          updated_at:     Time.current
        }
      end.compact

      Word.insert_all(word_attrs) if word_attrs.any?
      bump(:verses_imported)
      bump(:words_created, word_attrs.size)

      if (@stats[:verses_imported] || 0) % 500 == 0
        $stdout.puts "[CntrSrImporter] #{@stats[:verses_imported]} verses, #{@stats[:words_created]} words"
        $stdout.flush
      end
    end

    def ensure_lemma(lemma_text, standard_strongs)
      return nil if lemma_text.blank?
      key = [lemma_text, standard_strongs]
      return @lemma_cache[key] if @lemma_cache.key?(key)

      # Reuse an existing lemma keyed on this (standard, ESN-normalized)
      # Strong's before creating one from the surface form. After ESN
      # normalization (caller side), this matches what KJV / RP / BSB
      # write \u2014 single canonical lookup, no special trail-drop.
      lemma = find_lemma_by_strongs(standard_strongs, "el-koine")
      if lemma
        bump(:lemmas_resolved_by_strongs)
        return @lemma_cache[key] = lemma
      end

      normalized = lemma_text.unicode_normalize(:nfd).gsub(/[\u0300-\u036F]/, "").unicode_normalize(:nfc)
      l = Lemma.find_or_initialize_by(language: "el-koine", lemma: lemma_text)
      if l.new_record?
        l.assign_attributes(normalized: normalized, frequency: 0)
        stamp(l)
        l.save!
        bump(:lemmas_created)
      end
      @lemma_cache[key] = l
    end

    def next_work_unit_ord
      @next_ord ||= (WorkUnit.where(work_id: @work.id).maximum(:ord) || 0)
      @next_ord += 1
    end
  end
end
