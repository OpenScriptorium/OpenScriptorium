module Importers
  # Adds word-level morphology and lemma data to the existing Rahlfs
  # LXX Work from the CATSS morphologically tagged Septuagint.
  #
  # Source: nathans/lxxmorph-unicode on GitHub (Unicode conversion of
  # the CATSS / Tov-Polak morphological analysis of the LXX)
  # License: see CATSS project terms (academic use)
  #
  # Format: one word per line, verse headers like "Gen 1:1".
  # Each word line: surface_form  morph_code  lemma (tab-separated)
  #
  # The Rahlfs LXX Work and its work_units must already exist
  # (created by RahlfsImporter).
  class RahlfsMorphImporter < BaseImporter
    DEFAULT_DIR = Rails.root.join("tmp/catss_morph")

    # CATSS book names → our canonical_works.slug
    # CATSS has both "B" and "A" text variants for some books
    # (JoshB/JoshA, JudgesB/JudgesA). We use the B text (Vaticanus)
    # which is what Rahlfs prints as the main text.
    BOOK_MAP = {
      "Gen" => "genesis", "Exod" => "exodus", "Lev" => "leviticus",
      "Num" => "numbers", "Deut" => "deuteronomy",
      "JoshB" => "joshua", "JudgesB" => "judges", "Ruth" => "ruth",
      "1Sam" => "1-samuel", "2Sam" => "2-samuel",
      "1Kgs" => "1-kings", "2Kgs" => "2-kings",
      "1Chr" => "1-chronicles", "2Chr" => "2-chronicles",
      "1Esdr" => "1-esdras", "Ezra-Neh" => nil, # handled specially
      "Esth" => "esther",
      "Jdt" => "judith", "Tob" => "tobit",
      "1Macc" => "1-maccabees", "2Macc" => "2-maccabees",
      "3Macc" => "3-maccabees", "4Macc" => "4-maccabees",
      "Ps" => "psalms", "Odes" => "odes",
      "Prov" => "proverbs", "Qoh" => "ecclesiastes",
      "Song" => "song-of-solomon", "Job" => "job",
      "Wis" => "wisdom", "Sir" => "sirach",
      "PsSol" => "psalms-of-solomon",
      "Hos" => "hosea", "Amos" => "amos", "Mic" => "micah",
      "Joel" => "joel", "Obad" => "obadiah", "Jonah" => "jonah",
      "Nah" => "nahum", "Hab" => "habakkuk", "Zeph" => "zephaniah",
      "Hag" => "haggai", "Zech" => "zechariah", "Mal" => "malachi",
      "Isa" => "isaiah", "Jer" => "jeremiah", "Bar" => "baruch",
      "Lam" => "lamentations", "EpJer" => "letter-of-jeremiah",
      "Ezek" => "ezekiel",
      "DanielOG" => "daniel", "DanielTh" => nil, # skip Theodotion
      "SusOG" => "susanna", "SusTh" => nil,
      "BelOG" => "bel-and-the-dragon", "BelTh" => nil
    }.freeze

    # CATSS file prefix → book name used in verse headers
    FILE_TO_HEADER_BOOK = {
      "01.Gen" => "Gen", "02.Exod" => "Exod", "03.Lev" => "Lev",
      "04.Num" => "Num", "05.Deut" => "Deut",
      "06.JoshB" => "JoshB", "07.JoshA" => "JoshA",
      "08.JudgesB" => "JudgesB", "09.JudgesA" => "JudgesA",
      "10.Ruth" => "Ruth",
      "11.1Sam" => "1Sam", "12.2Sam" => "2Sam",
      "13.1Kgs" => "1Kgs", "14.2Kgs" => "2Kgs",
      "15.1Chr" => "1Chr", "16.2Chr" => "2Chr",
    }.freeze

    def initialize(dir: nil, **opts)
      super(**opts)
      @dir = dir || DEFAULT_DIR
    end

    protected

    def source_url
      "https://github.com/nathans/lxxmorph-unicode"
    end

    def source_format
      "tsv"
    end

    def transactional?
      false
    end

    def perform
      @rahlfs_work = Work.find_by!(slug: "rahlfs-lxx")
      @canonical_work_cache = {}
      @lemma_cache = {}

      # Wipe existing Rahlfs Word records for idempotency
      Word.where(work_id: @rahlfs_work.id).delete_all

      Dir.glob(File.join(@dir, "*.txt")).sort.each do |path|
        process_file(path)
      end

      @rahlfs_work.update!(has_word_data: true, last_imported_at: Time.current)
    end

    private

    VERSE_HEADER_RE = /\A(\S+)\s+(\d+):(\d+)\s*\z/

    def process_file(path)
      fname = File.basename(path, ".txt")
      # Extract book name from filename (e.g., "01.Gen" → "Gen")
      book_name = fname.sub(/\A\d+\./, "")
      slug = BOOK_MAP[book_name]
      return if slug.nil?  # explicitly skipped (Theodotion, A-texts, etc.)

      unless slug
        bump(:books_skipped)
        return
      end

      # Try the base slug, then LXX-specific variants
      canonical_work = find_canonical_work(slug)
      unless canonical_work
        bump(:books_no_canonical_work)
        Rails.logger.warn "[RahlfsMorphImporter] no canonical_work for #{slug}"
        return
      end

      current_chapter = 0
      current_verse = 0
      word_buffer = []

      File.foreach(path, encoding: "utf-8") do |line|
        line = line.chomp.strip
        next if line.empty?

        if (m = VERSE_HEADER_RE.match(line))
          flush_verse!(canonical_work, current_chapter, current_verse, word_buffer) if word_buffer.any?
          current_chapter = m[2].to_i
          current_verse = m[3].to_i
          word_buffer = []
          next
        end

        # Word line: surface  morph_code  lemma (space-separated,
        # where the morph code is always a fixed-width 10-char field
        # like "P---------" or "VAI-AAI3S-")
        parts = line.split(/\s+/)
        next if parts.size < 3
        word_buffer << {
          surface: parts[0].strip,
          morph:   parts[1].strip,
          lemma:   parts[2].strip
        }
      end
      flush_verse!(canonical_work, current_chapter, current_verse, word_buffer) if word_buffer.any?

      bump(:books_imported)
      if (@stats[:books_imported] || 0) % 5 == 0
        $stdout.puts "[RahlfsMorphImporter] #{@stats[:books_imported]} books, #{@stats[:words_created] || 0} words"
        $stdout.flush
      end
    end

    def flush_verse!(canonical_work, chapter, verse, words)
      return if chapter == 0 || verse == 0 || words.empty?

      canonical_ref = CanonicalRef.where(
        canonical_work_id: canonical_work.id,
        hierarchy: [chapter, verse]
      ).first

      # Create canonical_ref if missing (morphology source has verses
      # not in the text source)
      unless canonical_ref
        @cref_counters ||= {}
        @cref_counters[canonical_work.id] ||= (CanonicalRef.where(canonical_work_id: canonical_work.id).maximum(:ord) || 0)
        @cref_counters[canonical_work.id] += 1
        canonical_ref = CanonicalRef.create!(
          canonical_work_id: canonical_work.id,
          hierarchy: [chapter, verse],
          ord: @cref_counters[canonical_work.id],
          display_label: "#{chapter}:#{verse}",
          sbl_citation: canonical_work.format_citation([chapter, verse]),
          import_run_id: @import_run.id
        )
        bump(:canonical_refs_created)
      end

      work_unit = WorkUnit.find_by(work_id: @rahlfs_work.id, canonical_ref_id: canonical_ref.id)

      # Create work_unit if missing — reconstruct verse text from word surfaces
      unless work_unit
        body = words.map { |w| w[:surface] }.join(" ")
        @wu_counters ||= {}
        @wu_counters[@rahlfs_work.id] ||= (WorkUnit.where(work_id: @rahlfs_work.id).maximum(:ord) || 0)
        @wu_counters[@rahlfs_work.id] += 1
        work_unit = WorkUnit.create!(
          work_id: @rahlfs_work.id,
          canonical_ref_id: canonical_ref.id,
          ord: @wu_counters[@rahlfs_work.id],
          label: "#{chapter}:#{verse}",
          body: body,
          canonical_alignment_type: "exact",
          import_run_id: @import_run.id
        )
        bump(:work_units_created)
      end

      word_attrs = words.each_with_index.map do |w, idx|
        lemma = ensure_lemma(w[:lemma])
        {
          work_id:        @rahlfs_work.id,
          work_unit_id:   work_unit.id,
          position:       idx + 1,
          surface:        w[:surface],
          normalized:     w[:surface].unicode_normalize(:nfd).gsub(/[\u0300-\u036F]/, "").unicode_normalize(:nfc),
          lemma_id:       lemma&.id,
          morph_code:     w[:morph],
          strongs_number: nil,
          import_run_id:  @import_run.id,
          notes:          {},
          created_at:     Time.current,
          updated_at:     Time.current
        }
      end

      Word.insert_all(word_attrs) if word_attrs.any?
      bump(:words_created, word_attrs.size)
    end

    def ensure_lemma(lemma_text)
      return nil if lemma_text.blank? || lemma_text == "-"
      cached = @lemma_cache[lemma_text]
      return cached if cached

      normalized = lemma_text.unicode_normalize(:nfd).gsub(/[\u0300-\u036F]/, "").unicode_normalize(:nfc)
      l = Lemma.find_or_initialize_by(language: "el-koine", lemma: lemma_text)
      if l.new_record?
        l.assign_attributes(normalized: normalized, frequency: 0)
        stamp(l)
        l.save!
        bump(:lemmas_created)
      end
      @lemma_cache[lemma_text] = l
    end

    def find_canonical_work(slug)
      # Try base slug first, then LXX-specific variants
      cw = (@canonical_work_cache[slug] ||= CanonicalWork.find_by(slug: slug))
      return cw if cw
      lxx_slug = "#{slug}-lxx"
      @canonical_work_cache[lxx_slug] ||= CanonicalWork.find_by(slug: lxx_slug)
    end
  end
end
