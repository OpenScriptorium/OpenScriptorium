module Importers
  # Adds translator footnotes to the existing Brenton LXX Work from
  # the eBible.org USFM edition.
  #
  # The Brenton Work and its work_units must already exist (created
  # by BrentonImporter from the VPL). This importer reads the USFM
  # files and extracts \f...\f* footnotes, creating WorkUnitNote
  # rows for each.
  #
  # Brenton's footnotes are mostly "Gr. ..." (literal Greek reading)
  # and "Heb. ..." (Hebrew reading where LXX diverges from MT).
  # These are classified as "translation" type notes.
  class BrentonNotesImporter < BaseImporter
    DEFAULT_DIR = Rails.root.join("tmp/brenton/usfm")

    # Reuse the same book map as BrentonImporter
    BOOK_MAP = BrentonImporter::BOOK_MAP

    FOOTNOTE_RE = /\\f\s+\+\s+\\fr\s+([\d:]+)\s+(.*?)\\f\*/

    def initialize(dir: nil, **opts)
      super(**opts)
      @dir = dir || DEFAULT_DIR
    end

    protected

    def source_url
      "https://ebible.org/Scriptures/eng-Brenton_usfm.zip"
    end

    def source_format
      "usfm"
    end

    def transactional?
      false
    end

    def perform
      @brenton = Work.find_by!(slug: "brenton-lxx")
      @canonical_work_cache = {}

      # Wipe existing notes for idempotency
      bsb_unit_ids = WorkUnit.where(work_id: @brenton.id).pluck(:id)
      WorkUnitNote.where(work_unit_id: bsb_unit_ids).delete_all

      Dir.glob(File.join(@dir, "*.usfm")).sort.each do |path|
        process_file(path)
      end
    end

    private

    def process_file(path)
      fname = File.basename(path, ".usfm")
      m = fname.match(/\d+-(\w{3})/)
      return unless m
      book_code = m[1].upcase
      slug = BOOK_MAP[book_code]
      return unless slug

      canonical_work = (@canonical_work_cache[slug] ||= CanonicalWork.find_by(slug: slug))
      return unless canonical_work

      current_chapter = 0
      File.foreach(path, encoding: "utf-8") do |line|
        line = line.chomp
        current_chapter = $1.to_i if line =~ /\\c\s+(\d+)/
        next unless line =~ /\\v\s+(\d+)\s+(.*)/
        verse_n = $1.to_i
        verse_usfm = $2

        # Extract footnotes from this verse
        note_idx = 0
        verse_usfm.scan(FOOTNOTE_RE) do |ref, body|
          process_footnote(canonical_work, current_chapter, verse_n, body, note_idx)
          note_idx += 1
        end
      end
      bump(:books_processed)
    end

    def process_footnote(canonical_work, chapter, verse_n, raw_body, position)
      canonical_ref = CanonicalRef.where(
        canonical_work_id: canonical_work.id,
        hierarchy: [chapter, verse_n]
      ).first
      return unless canonical_ref

      work_unit = WorkUnit.find_by(work_id: @brenton.id, canonical_ref_id: canonical_ref.id)
      return unless work_unit

      # Strip USFM footnote markup to get clean text
      body = raw_body
        .gsub(/\\fqa\s*/, "")   # alternate text marker
        .gsub(/\\ft\s*/, "")    # footnote text marker
        .gsub(/\\fr\s*[\d:]+\s*/, "")  # footnote reference
        .gsub(/\\[a-z]+\s*/i, "")  # any remaining markers
        .gsub(/\s+/, " ")
        .strip

      return if body.empty?

      # Classify note type
      type = case body
             when /\AGr\.\s/i    then "translation"
             when /\AHeb\.\s/i   then "translation"
             when /\AOr,?\s/i    then "textual"
             when /\ALit\.\s/i   then "translation"
             else                     "explanation"
             end

      # Extract anchor text (the word right before the \f marker in the verse)
      # We don't have precise position data, so leave anchor_text nil
      note = WorkUnitNote.new(
        work_unit:        work_unit,
        position_in_unit: position,
        note_type:        type,
        anchor_text:      nil,
        body:             body,
        import_run_id:    @import_run.id
      )
      note.save!
      bump(:notes_created)
    end
  end
end
