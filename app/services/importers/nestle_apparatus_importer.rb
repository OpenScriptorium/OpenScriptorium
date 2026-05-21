require "json"

module Importers
  # Imports the Nestle 1904 critical apparatus extracted from the PD
  # print edition via WHNU-guided OCR verification.
  #
  # Source: Nestle 1904 DjVu text from archive.org (public domain),
  # cross-referenced against the WHNU SWORD module (used as a guide
  # only — no WHNU data is redistributed).
  #
  # The input is tmp/nestle_apparatus/final_apparatus.json, containing
  # 1,229 variant pairs with verse references, WH reading, and NU
  # reading. Each entry represents a place where Westcott-Hort and
  # the Nestle/NA tradition disagree.
  #
  # The importer creates VariantUnit + Reading rows for the Nestle
  # 1904 work's canonical_refs. It does NOT create ReadingWitness
  # rows (we don't have per-manuscript attestation from this source —
  # that comes from the CNTR transcriptions import #81).
  class NestleApparatusImporter < BaseImporter
    # The 712 curated variant pairs ship with the repo at
    # db/seeds/nestle_apparatus.json — that's the source of truth.
    # `script/extract_nestle_apparatus.py` produces an unreviewed
    # apparatus.json from the PDF; the curated/reviewed version is
    # what we commit and import.
    DEFAULT_PATH = Rails.root.join("db/seeds/nestle_apparatus.json")

    BOOK_TO_SLUG = {
      "Matt" => "matthew", "Mark" => "mark", "Luke" => "luke",
      "John" => "john", "Acts" => "acts", "Rom" => "romans",
      "1Cor" => "1-corinthians", "2Cor" => "2-corinthians",
      "Gal" => "galatians", "Eph" => "ephesians",
      "Phil" => "philippians", "Col" => "colossians",
      "1Thess" => "1-thessalonians", "2Thess" => "2-thessalonians",
      "1Tim" => "1-timothy", "2Tim" => "2-timothy",
      "Titus" => "titus", "Phlm" => "philemon",
      "Heb" => "hebrews", "Jas" => "james",
      "1Pet" => "1-peter", "2Pet" => "2-peter",
      "1John" => "1-john", "2John" => "2-john", "3John" => "3-john",
      "Jude" => "jude", "Rev" => "revelation"
    }.freeze

    def initialize(path: nil, **opts)
      super(**opts)
      @path = path || DEFAULT_PATH
    end

    protected

    def source_url
      "https://archive.org/details/nestles-greek-new-testament-bfbs-and-us-editions-1904-with-translation-1905"
    end

    def source_format
      "json"
    end

    def transactional?
      true
    end

    def perform
      unless File.exist?(@path)
        raise "Missing #{@path} — apparatus seed should be committed at this path"
      end

      @nestle_work = Work.find_by!(slug: "nestle1904")
      @canonical_work_cache = {}

      # Wipe existing Nestle apparatus for idempotency.
      # Scope by import_run to avoid deleting CNTR apparatus data that
      # shares the same NT canonical_refs.
      nestle_run_ids = ImportRun.where(importer_class: self.class.name).pluck(:id)
      old_vus = VariantUnit.where(import_run_id: nestle_run_ids)
      if old_vus.any?
        old_reading_ids = Reading.where(variant_unit_id: old_vus.select(:id)).pluck(:id)
        ReadingWitness.where(reading_id: old_reading_ids).delete_all if old_reading_ids.any?
        old_vus.update_all(base_reading_id: nil)
        Reading.where(id: old_reading_ids).delete_all if old_reading_ids.any?
        old_vus.delete_all
      end

      entries = JSON.parse(File.read(@path))
      Rails.logger.info "[NestleApparatusImporter] loading #{entries.size} apparatus entries"

      entries.each do |entry|
        process_entry(entry)
      end
    end

    private

    def process_entry(entry)
      verse_ref = entry["verse"]
      parts = verse_ref.split(".")
      return unless parts.size == 3

      book_code = parts[0]
      chapter = parts[1].to_i
      verse_n = parts[2].to_i

      slug = BOOK_TO_SLUG[book_code]
      unless slug
        bump(:unknown_book)
        return
      end

      canonical_work = (@canonical_work_cache[slug] ||= CanonicalWork.find_by(slug: slug))
      return unless canonical_work

      canonical_ref = CanonicalRef.where(
        canonical_work_id: canonical_work.id,
        hierarchy: [chapter, verse_n]
      ).first
      unless canonical_ref
        bump(:no_canonical_ref)
        return
      end

      wh_reading = entry["wh_reading"].to_s.strip
      nu_reading = entry["nu_reading"].to_s.strip

      # Determine which is the base (Nestle) reading and which is the variant.
      # Nestle 1904 generally follows the NU (Nestle-Aland) tradition,
      # so the NU reading is typically the base text and WH is the variant.
      base_text = nu_reading.present? ? nu_reading : wh_reading
      variant_text = nu_reading.present? ? wh_reading : nu_reading

      # Determine variant type
      variant_type = if wh_reading.empty?
        "addition"      # NU adds text that WH omits
      elsif nu_reading.empty?
        "omission"       # NU omits text that WH has
      else
        "substitution"   # different readings
      end

      # Position within ref = count of existing VUs for this ref + 1
      position = (VariantUnit.where(canonical_ref_id: canonical_ref.id).maximum(:position_within_ref) || 0) + 1

      vu = VariantUnit.new(
        canonical_ref: canonical_ref,
        position_within_ref: position,
        lemma_text: base_text,
        variant_type: variant_type,
        import_run_id: @import_run.id
      )
      stamp(vu)
      vu.save!

      # Base reading (Nestle/NU text)
      base = Reading.new(
        variant_unit: vu,
        text: base_text.present? ? base_text : "(omit)",
        normalized_text: base_text.downcase,
        notes: "Nestle 1904 / NA reading",
        import_run_id: @import_run.id
      )
      base.save!
      vu.update!(base_reading_id: base.id)

      # Variant reading (WH text)
      variant = Reading.new(
        variant_unit: vu,
        text: variant_text.present? ? variant_text : "(omit)",
        normalized_text: variant_text.downcase,
        notes: "Westcott-Hort reading",
        import_run_id: @import_run.id
      )
      variant.save!

      bump(:variants_imported)
    end
  end
end
