module Importers
  # Adds Ketiv/Qere notes and parashot to the existing WLC Work from
  # the OSHB "Miqra according to the Mesorah" (MAPM) XML.
  #
  # Source: OpenScriptures Hebrew Bible — MAPM.xml
  # License: CC BY-SA 3.0
  # Coverage: 39 OT books (full Hebrew Bible / Tanakh)
  #
  # Features imported:
  #   - Ketiv/Qere notes (953 instances) → WorkUnitNote (textual)
  #   - Parashot / Torah sections (59) → Pericope (parashah, jewish_liturgical)
  #   - Paragraph breaks (petuhah/setumah) → work_units.markup["paragraph_break"]
  class OshbFeaturesImporter < BaseImporter
    DEFAULT_PATH = Rails.root.join("tmp/oshb/MAPM.xml")

    OSIS_TO_SLUG = {
      "Gen" => "genesis", "Exod" => "exodus", "Lev" => "leviticus",
      "Num" => "numbers", "Deut" => "deuteronomy", "Josh" => "joshua",
      "Judg" => "judges", "Ruth" => "ruth",
      "1Sam" => "1-samuel", "2Sam" => "2-samuel",
      "1Kgs" => "1-kings", "2Kgs" => "2-kings",
      "1Chr" => "1-chronicles", "2Chr" => "2-chronicles",
      "Ezra" => "ezra", "Neh" => "nehemiah", "Esth" => "esther",
      "Job" => "job", "Ps" => "psalms", "Prov" => "proverbs",
      "Eccl" => "ecclesiastes", "Song" => "song-of-solomon",
      "Isa" => "isaiah", "Jer" => "jeremiah", "Lam" => "lamentations",
      "Ezek" => "ezekiel", "Dan" => "daniel",
      "Hos" => "hosea", "Joel" => "joel", "Amos" => "amos",
      "Obad" => "obadiah", "Jonah" => "jonah", "Mic" => "micah",
      "Nah" => "nahum", "Hab" => "habakkuk", "Zeph" => "zephaniah",
      "Hag" => "haggai", "Zech" => "zechariah", "Mal" => "malachi"
    }.freeze

    def initialize(path: nil, **opts)
      super(**opts)
      @path = path || DEFAULT_PATH
    end

    protected

    def source_url
      "https://hb.openscriptures.org/"
    end

    def source_format
      "osis_xml"
    end

    def transactional?
      false
    end

    SOURCE_FILE_URL = "https://raw.githubusercontent.com/openscriptures/morphhb/master/MAPM/MAPM.xml".freeze

    def perform
      download_source unless File.exist?(@path)

      @wlc = Work.find_by!(slug: "wlc")
      @canonical_work_cache = {}
      @work_unit_cache = {}

      # Wipe existing notes from this source for idempotency
      wlc_unit_ids = WorkUnit.where(work_id: @wlc.id).pluck(:id)
      deleted = WorkUnitNote.where(work_unit_id: wlc_unit_ids).delete_all
      bump(:old_notes_deleted, deleted)

      # Wipe existing OSHB parashot for idempotency
      Pericope.where(source_dataset: "oshb_parashot").delete_all

      parse_mapm
      update_pericope_traditions

      @wlc.update!(last_imported_at: Time.current)
    end

    def download_source
      require "open-uri"
      FileUtils.mkdir_p(File.dirname(@path))
      Rails.logger.info "[OshbFeaturesImporter] downloading #{SOURCE_FILE_URL}"
      File.binwrite(@path, URI.open(SOURCE_FILE_URL).read)
      bump(:source_downloaded)
    end

    private

    def parse_mapm
      xml = File.read(@path, encoding: "utf-8")

      # Extract parashot (Torah sections)
      extract_parashot(xml)

      # Process verse by verse for ketiv/qere and paragraph breaks
      current_book = nil
      current_chapter = 0
      pending_paragraph_break = false

      xml.each_line do |line|
        # Track current book
        if line =~ /osisID="([A-Za-z0-9]+)\.\d/
          new_book = $1
          if new_book != current_book
            current_book = new_book
            current_chapter = 0
          end
        end

        # Track chapter
        if line =~ /chapter osisID="[^"]*" sID="[^"]*" n="[^"]*"/
          current_chapter += 1
        end

        # Paragraph break: double <lb/> between verses
        if line =~ /<lb\/>/
          pending_paragraph_break = true
        end

        # Verse line
        if line =~ /verse osisID="([^"]+)" sID/
          osis_id = $1
          book_osis, ch_s, v_s = osis_id.split(".")
          slug = OSIS_TO_SLUG[book_osis]
          next unless slug

          chapter = ch_s.to_i
          verse = v_s.to_i

          # Apply paragraph break from preceding <lb/> to this verse
          if pending_paragraph_break
            mark_paragraph_break(slug, chapter, verse)
            pending_paragraph_break = false
          end

          # Extract ketiv/qere
          extract_ketiv_qere(line, slug, chapter, verse)
        end

        # Reset paragraph flag on non-lb, non-blank lines
        pending_paragraph_break = false if line.strip != "" && !line.include?("<lb/>") && !line.include?("verse")
      end
    end

    def extract_ketiv_qere(line, slug, chapter, verse)
      # Pattern: <seg type="x-ketiv">KETIV</seg> QERE_FOLLOWS
      # The ketiv (written) form is inside the seg tag.
      # The qere (read) form follows immediately after the closing tag.
      line.scan(/<seg type="x-ketiv">([^<]+)<\/seg>\s*(\S+)/) do |ketiv, qere|
        # Clean up qere: strip cantillation/vowels for display but keep as-is
        work_unit = find_work_unit(slug, chapter, verse)
        next unless work_unit

        body = "Ketiv: #{ketiv}; Qere: #{qere}"
        note = WorkUnitNote.new(
          work_unit: work_unit,
          position_in_unit: next_note_position(work_unit.id),
          note_type: "textual",
          body: body,
          import_run_id: @import_run.id
        )
        note.save!
        bump(:ketiv_qere_notes)
      end
    end

    def mark_paragraph_break(slug, chapter, verse)
      work_unit = find_work_unit(slug, chapter, verse)
      return unless work_unit

      markup = work_unit.markup || {}
      markup["paragraph_break"] = true
      work_unit.update!(markup: markup)
      bump(:paragraph_breaks)
    end

    def extract_parashot(xml)
      # Torah sections: <div type="section" scope="Gen.1.1-Gen.6.8">
      #                   <title>בראשית</title>
      # Psalm books:    <div type="section" scope="Ps.1-Ps.41">
      #                   <title>ספר ראשון</title>
      sequence = 0
      xml.scan(/<div type="section" scope="([^"]+)">\s*\n\s*<title>([^<]+)<\/title>/) do |scope, title|
        start_ref, end_ref = scope.split("-")
        next unless start_ref && end_ref

        start_parts = start_ref.split(".")
        end_parts = end_ref.split(".")

        start_slug = OSIS_TO_SLUG[start_parts[0]]
        end_slug = OSIS_TO_SLUG[end_parts[0]]
        next unless start_slug && end_slug

        canonical_work = find_canonical_work(start_slug)
        next unless canonical_work

        # Handle chapter-only scope (Ps.1-Ps.41) vs verse scope (Gen.1.1-Gen.6.8)
        if start_parts.length == 2
          # Chapter-only: start at ch:1, end at last verse of end chapter
          start_cref = CanonicalRef.where(
            canonical_work_id: canonical_work.id,
            hierarchy: [start_parts[1].to_i, 1]
          ).first
          end_cref = CanonicalRef.where(canonical_work_id: canonical_work.id)
            .where("hierarchy[1] = ?", end_parts[1].to_i)
            .order(ord: :desc).first
          pericope_type = "section"
        else
          start_cref = CanonicalRef.where(
            canonical_work_id: canonical_work.id,
            hierarchy: [start_parts[1].to_i, start_parts[2].to_i]
          ).first
          end_cref = CanonicalRef.where(
            canonical_work_id: canonical_work.id,
            hierarchy: [end_parts[1].to_i, end_parts[2].to_i]
          ).first
          pericope_type = "parashah"
        end
        next unless start_cref && end_cref

        sequence += 1
        Pericope.create!(
          canonical_work: canonical_work,
          canonical_range: (start_cref.ord...end_cref.ord + 1),
          name: title.strip,
          pericope_type: pericope_type,
          tradition: "jewish_liturgical",
          source_dataset: "oshb_parashot",
          sequence_number: sequence,
          import_run_id: @import_run.id
        )
        bump(:parashot_created)
      end
    end

    def find_canonical_work(slug)
      @canonical_work_cache[slug] ||= CanonicalWork.find_by(slug: slug)
    end

    def find_work_unit(slug, chapter, verse)
      key = "#{slug}:#{chapter}:#{verse}"
      return @work_unit_cache[key] if @work_unit_cache.key?(key)

      canonical_work = find_canonical_work(slug)
      return nil unless canonical_work

      cref = CanonicalRef.where(
        canonical_work_id: canonical_work.id,
        hierarchy: [chapter, verse]
      ).first
      return nil unless cref

      wu = WorkUnit.find_by(work_id: @wlc.id, canonical_ref_id: cref.id)
      @work_unit_cache[key] = wu
      wu
    end

    def next_note_position(work_unit_id)
      @note_positions ||= Hash.new(0)
      pos = @note_positions[work_unit_id]
      @note_positions[work_unit_id] += 1
      pos
    end

    def update_pericope_traditions
      # Add jewish_liturgical to WLC's pericope_traditions if not present
      traditions = @wlc.pericope_traditions || []
      unless traditions.include?("jewish_liturgical")
        traditions << "jewish_liturgical"
        @wlc.update!(pericope_traditions: traditions)
      end
    end
  end
end
