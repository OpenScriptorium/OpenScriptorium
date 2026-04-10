module Importers
  # Imports critical apparatus data from the CNTR manuscript transcription
  # files, comparing each manuscript's reading against the CNTR Statistical
  # Restoration base text to generate variant_units / readings /
  # reading_witnesses rows.
  #
  # Source: Center-for-New-Testament-Restoration/transcriptions on GitHub
  # License: CC BY-SA 4.0
  # Format: plain-text manuscript transcription files (one per witness)
  #
  # Each file is named by Gregory-Aland number (e.g. "01.txt" = Sinaiticus).
  # Lines are: OSIS verse ref + space-separated words with notation for
  # corrections, nomina sacra, damage, etc.
  class CntrApparatusImporter < BaseImporter
    REPO_URL  = "https://github.com/Center-for-New-Testament-Restoration/transcriptions".freeze
    CLONE_DIR = Rails.root.join("tmp/cntr_transcriptions").freeze

    # Reuse the book-number map from the SR importer.
    BOOK_NUM_TO_SLUG = CntrSrImporter::BOOK_NUM_TO_SLUG

    # Known manuscript sigla. Keys are the filename stems (sans .txt) that
    # appear in the four class directories. Values are display sigla used
    # in scholarly apparatus.  This list covers the most important uncials
    # and a handful of papyri; manuscripts not listed here get their
    # filename stem as siglum.
    SIGLA = {
      "01"  => "\u2135",       # Sinaiticus
      "02"  => "A",            # Alexandrinus
      "03"  => "B",            # Vaticanus
      "04"  => "C",            # Ephraemi Rescriptus
      "05"  => "D",            # Bezae
      "06"  => "D\u1D56",      # Claromontanus (Dᵖ)
      "032" => "W",            # Washingtonianus
      "033" => "\u0398",       # Koridethi (Θ)
      "044" => "\u03A8",       # Athous Lavrensis (Ψ)
      "P45" => "\U0001D513\u2074\u2075",
      "P46" => "\U0001D513\u2074\u2076",
      "P47" => "\U0001D513\u2074\u2077",
      "P66" => "\U0001D513\u2076\u2076",
      "P72" => "\U0001D513\u2077\u2072",
      "P75" => "\U0001D513\u2077\u2075"
    }.freeze

    # Manuscript metadata (GA number => { name:, date_text:, date_year_estimate:, material:, format:, family: })
    MANUSCRIPT_META = {
      "01"  => { name: "Codex Sinaiticus",          date_text: "4th c.",  date_year_estimate: 350, material: "vellum",   format: "codex", family: "alexandrian" },
      "02"  => { name: "Codex Alexandrinus",         date_text: "5th c.",  date_year_estimate: 450, material: "vellum",   format: "codex", family: "byzantine" },
      "03"  => { name: "Codex Vaticanus",            date_text: "4th c.",  date_year_estimate: 325, material: "vellum",   format: "codex", family: "alexandrian" },
      "04"  => { name: "Codex Ephraemi Rescriptus",  date_text: "5th c.",  date_year_estimate: 450, material: "vellum",   format: "codex", family: "alexandrian" },
      "05"  => { name: "Codex Bezae",                date_text: "5th c.",  date_year_estimate: 450, material: "vellum",   format: "codex", family: "western" },
      "06"  => { name: "Codex Claromontanus",        date_text: "6th c.",  date_year_estimate: 550, material: "vellum",   format: "codex", family: "western" },
      "032" => { name: "Codex Washingtonianus",      date_text: "4th/5th c.", date_year_estimate: 400, material: "vellum", format: "codex", family: "other" },
      "033" => { name: "Codex Koridethi",            date_text: "9th c.",  date_year_estimate: 850, material: "vellum",   format: "codex", family: "caesarean" },
      "044" => { name: "Codex Athous Lavrensis",     date_text: "8th/9th c.", date_year_estimate: 825, material: "vellum", format: "codex", family: "alexandrian" }
    }.freeze

    # CNTR transcription file classes and their subdirectories
    MS_CLASSES = ["class 1", "class 2", "class 3", "critical texts"].freeze

    def initialize(download: true, **opts)
      super(**opts)
      @download = download
    end

    protected

    def source_url
      REPO_URL
    end

    def source_format
      "txt"
    end

    # This is a very large import; we commit in batches, not one big txn.
    def transactional?
      false
    end

    def perform
      download_transcriptions! if @download

      @sr_work = Work.find_by!(slug: "cntr-sr")
      @canonical_work_cache = {}
      @canonical_ref_cache  = {}  # [slug, chapter, verse] => CanonicalRef
      @base_text_cache      = {}  # canonical_ref_id => normalized koine text

      # Phase 1: ensure Manuscript rows
      ms_files = discover_manuscript_files
      @manuscript_cache = {}  # ga_number string => Manuscript record
      ms_files.each { |ga, _path| ensure_manuscript(ga) }
      bump(:manuscripts, @manuscript_cache.size)
      $stdout.puts "[CntrApparatus] #{@manuscript_cache.size} manuscripts registered"

      # Phase 2: load all SR base-text work_units keyed by canonical_ref_id
      load_base_texts!
      $stdout.puts "[CntrApparatus] #{@base_text_cache.size} SR base-text verses cached"

      # Phase 3: collect per-verse readings from every manuscript
      # verse_readings: { canonical_ref_id => { normalized_text => { text: display, witnesses: [[ga, layer], ...] } } }
      verse_readings = Hash.new { |h, k| h[k] = {} }

      ms_files.each do |ga, path|
        parse_manuscript_file(ga, path, verse_readings)
      end
      $stdout.puts "[CntrApparatus] readings collected, generating apparatus..."

      # Phase 4: generate variant_units / readings / reading_witnesses
      generate_apparatus!(verse_readings)
    end

    private

    # ---- Download -------------------------------------------------------

    def download_transcriptions!
      if CLONE_DIR.exist? && CLONE_DIR.join(".git").exist?
        $stdout.puts "[CntrApparatus] updating existing clone..."
        system("git", "-C", CLONE_DIR.to_s, "pull", "--ff-only", exception: true)
      else
        $stdout.puts "[CntrApparatus] cloning transcriptions repo..."
        FileUtils.mkdir_p(CLONE_DIR.parent)
        system("git", "clone", "--depth", "1",
               "#{REPO_URL}.git", CLONE_DIR.to_s,
               exception: true)
      end
    end

    # ---- Manuscript discovery -------------------------------------------

    # Returns array of [ga_number_string, Pathname] for every .txt file
    # found across the four class directories.
    def discover_manuscript_files
      results = []
      MS_CLASSES.each do |cls|
        dir = CLONE_DIR.join(cls)
        next unless dir.exist?
        Dir.glob(dir.join("*.txt")).sort.each do |path|
          ga = File.basename(path, ".txt")
          results << [ga, Pathname.new(path)]
        end
      end
      results
    end

    def ensure_manuscript(ga)
      return @manuscript_cache[ga] if @manuscript_cache.key?(ga)

      siglum = SIGLA.fetch(ga, ga)
      meta   = MANUSCRIPT_META.fetch(ga, {})

      ms = Manuscript.find_or_initialize_by(siglum: siglum)
      ms.assign_attributes(
        gregory_aland_number: ga,
        name:                 meta[:name],
        date_text:            meta[:date_text],
        date_year_estimate:   meta[:date_year_estimate],
        material:             meta[:material],
        format:               meta[:format],
        family:               meta[:family],
        language:             "el-koine"
      )
      stamp(ms)
      ms.save!
      @manuscript_cache[ga] = ms
    end

    # ---- Base text cache ------------------------------------------------

    def load_base_texts!
      WorkUnit.where(work_id: @sr_work.id)
              .where.not(canonical_ref_id: nil)
              .select(:id, :canonical_ref_id, :body)
              .find_each do |wu|
        @base_text_cache[wu.canonical_ref_id] = normalize_koine(wu.body)
      end
    end

    # ---- Manuscript file parsing ----------------------------------------

    def parse_manuscript_file(ga, path, verse_readings)
      File.open(path, "r:utf-8") do |f|
        f.each_line do |line|
          line = line.chomp.strip
          next if line.empty? || line.start_with?("#")

          # Split on first space: verse ref + rest
          ref_str, *tokens = line.split(/\s+/)
          next unless ref_str =~ /\A\d{8,9}\z/

          parsed = parse_verse_ref(ref_str) or next
          book_num, chapter, verse_n = parsed
          slug = BOOK_NUM_TO_SLUG[book_num] or next

          cref = find_canonical_ref(slug, chapter, verse_n) or next
          next unless @base_text_cache.key?(cref.id)  # only compare verses we have SR for

          # Reconstruct the verse text from tokens, handling correction
          # notation. CNTR uses x{original} {corrected} pairs.
          text = extract_first_hand_text(tokens)
          display_text = text
          normalized   = normalize_koine(text)
          next if normalized.blank?

          entry = verse_readings[cref.id]
          if entry.key?(normalized)
            entry[normalized][:witnesses] << [ga, "*"]
          else
            entry[normalized] = { text: display_text, witnesses: [[ga, "*"]] }
          end

          # Also record corrected readings if present
          corrected = extract_corrected_text(tokens)
          if corrected
            cnorm = normalize_koine(corrected)
            if cnorm.present? && cnorm != normalized
              if entry.key?(cnorm)
                entry[cnorm][:witnesses] << [ga, "c"]
              else
                entry[cnorm] = { text: corrected, witnesses: [[ga, "c"]] }
              end
            end
          end
        end
      end
      bump(:files_parsed)
      if (@stats[:files_parsed] || 0) % 20 == 0
        $stdout.puts "[CntrApparatus] #{@stats[:files_parsed]} files parsed"
        $stdout.flush
      end
    end

    # ---- Text extraction from CNTR notation -----------------------------

    # Extracts the *first-hand* (original) reading from a token array.
    # x{original reading} {corrected reading}
    # For the first hand, we take x{...} contents and skip {...} contents.
    def extract_first_hand_text(tokens)
      raw = tokens.join(" ")
      # Replace x{...} with its contents (first hand) and remove {...} (correction)
      text = raw.gsub(/x\{([^}]*)\}/) { $1 }
      text = text.gsub(/\{[^}]*\}/, "")
      strip_notation(text)
    end

    # Extracts the *corrected* reading if corrections exist; nil otherwise.
    def extract_corrected_text(tokens)
      raw = tokens.join(" ")
      return nil unless raw.include?("x{")
      # Replace x{...} with nothing (discard first hand) and {...} with contents
      text = raw.gsub(/x\{[^}]*\}/, "")
      text = text.gsub(/\{([^}]*)\}/) { $1 }
      strip_notation(text)
    end

    # Strip CNTR transcription notation markers, leaving only the Greek text.
    def strip_notation(text)
      text = text.dup
      text.gsub!(/\\[\d]+/, "")      # page markers like \522
      text.gsub!(%r{/}, "")           # line breaks
      text.gsub!("=", "")             # nomina sacra prefix
      text.gsub!("\u00AF", "")        # macron (abbreviation mark ¯)
      text.gsub!("%", "")             # damaged/uncertain
      text.gsub!("^", "")             # supralinear
      text.gsub!("~", "")             # other notation
      text.gsub!(/<[^>]*>/, "")       # any angle-bracket tags
      text.gsub!(/\s+/, " ")
      text.strip
    end

    # ---- Normalization --------------------------------------------------

    # Normalize koine Greek text for comparison: lowercase, strip accents
    # and breathing marks, collapse whitespace.
    def normalize_koine(text)
      return "" if text.blank?
      n = text.unicode_normalize(:nfd)
      n = n.gsub(/[\u0300-\u036F]/, "")  # strip combining diacriticals
      n = n.unicode_normalize(:nfc)
      n = n.downcase
      n = n.gsub(/[^\p{Greek}\s]/, "")   # keep only Greek letters + space
      n = n.gsub(/\s+/, " ").strip
      n
    end

    # ---- Verse ref parsing ----------------------------------------------

    def parse_verse_ref(ref)
      return nil unless ref =~ /\A(\d{2})(\d{3})(\d{3})\z/
      [$1.to_i, $2.to_i, $3.to_i]
    end

    def find_canonical_ref(slug, chapter, verse_n)
      key = [slug, chapter, verse_n]
      return @canonical_ref_cache[key] if @canonical_ref_cache.key?(key)

      cw = (@canonical_work_cache[slug] ||= CanonicalWork.find_by(slug: slug))
      return nil unless cw

      cref = CanonicalRef.where(
        canonical_work_id: cw.id,
        hierarchy: [chapter, verse_n]
      ).first

      @canonical_ref_cache[key] = cref
    end

    # ---- Apparatus generation -------------------------------------------

    def generate_apparatus!(verse_readings)
      # Process in batches by canonical_ref_id
      total = verse_readings.size
      processed = 0

      verse_readings.each do |cref_id, readings_hash|
        base_normalized = @base_text_cache[cref_id]

        # Only create apparatus where at least one manuscript diverges from SR
        variant_texts = readings_hash.reject { |norm, _| norm == base_normalized }
        next if variant_texts.empty?

        # Idempotency: find or create variant_unit for this verse
        vu = VariantUnit.find_or_initialize_by(
          canonical_ref_id:    cref_id,
          position_within_ref: 1
        )
        vu.assign_attributes(
          variant_type: classify_variant(base_normalized, variant_texts),
          notes:        "Auto-generated from CNTR manuscript transcriptions"
        )
        stamp(vu)
        vu.save!

        # For idempotency, clear old readings from a previous run
        old_reading_ids = Reading.where(variant_unit_id: vu.id).pluck(:id)
        if old_reading_ids.any?
          vu.update_column(:base_reading_id, nil)
          ReadingWitness.where(reading_id: old_reading_ids).delete_all
          Reading.where(id: old_reading_ids).delete_all
        end

        # Base reading (the SR text)
        base_entry = readings_hash[base_normalized]
        base_display = base_entry ? base_entry[:text] : ""
        # If no manuscript matched SR exactly, use the SR work_unit body
        if base_display.blank?
          wu = WorkUnit.find_by(work_id: @sr_work.id, canonical_ref_id: cref_id)
          base_display = wu&.body || ""
        end

        base_reading = vu.readings.create!(
          text:            base_display,
          normalized_text: base_normalized,
          is_base:         true,
          import_run_id:   @import_run.id
        )
        vu.update!(base_reading_id: base_reading.id)

        # Witnesses for the base reading
        if base_entry
          create_witnesses!(base_reading, base_entry[:witnesses])
        end

        # Variant readings
        variant_texts.each do |norm, entry|
          reading = vu.readings.create!(
            text:            entry[:text],
            normalized_text: norm,
            is_base:         false,
            import_run_id:   @import_run.id
          )
          create_witnesses!(reading, entry[:witnesses])
          bump(:variant_readings_created)
        end

        bump(:variant_units_created)
        processed += 1

        if processed % 500 == 0
          $stdout.puts "[CntrApparatus] #{processed}/#{total} variant units generated"
          $stdout.flush
        end
      end

      $stdout.puts "[CntrApparatus] done: #{@stats[:variant_units_created]} variant units, #{@stats[:variant_readings_created]} variant readings"
    end

    def create_witnesses!(reading, witnesses)
      witnesses.each do |ga, layer|
        ms = @manuscript_cache[ga]
        next unless ms

        # Skip duplicate witness for same reading+manuscript (can happen
        # if first-hand and correction both match the same text)
        next if ReadingWitness.exists?(reading_id: reading.id, manuscript_id: ms.id)

        ReadingWitness.create!(
          reading_id:       reading.id,
          manuscript_id:    ms.id,
          correction_layer: layer,
          certainty:        "certain",
          import_run_id:    @import_run.id
        )
        bump(:witnesses_created)
      end
    end

    # Simple heuristic to classify variant type based on token counts.
    def classify_variant(base_norm, variant_texts)
      base_tokens = base_norm.split.size
      variant_texts.each_key do |norm|
        vt = norm.split.size
        return "omission"  if vt == 0
        return "addition"  if base_tokens == 0
        return "omission"  if vt < base_tokens * 0.5
        return "addition"  if vt > base_tokens * 1.5
      end
      "substitution"
    end
  end
end
