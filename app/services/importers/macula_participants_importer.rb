require "nokogiri"

module Importers
  class MaculaParticipantsImporter < BaseImporter
    HEBREW_DIR = Rails.root.join("tmp/macula-hebrew/WLC/lowfat")
    GREEK_DIR  = Rails.root.join("tmp/macula-greek/Nestle1904/lowfat")

    BOOK_MAP = MaculaSyntaxImporter::BOOK_MAP

    # Macula book numbers → OSIS book codes (OT 1-39, NT 40-66)
    BOOK_NUMBERS = {
      1 => "GEN", 2 => "EXO", 3 => "LEV", 4 => "NUM", 5 => "DEU",
      6 => "JOS", 7 => "JDG", 8 => "RUT",
      9 => "1SA", 10 => "2SA", 11 => "1KI", 12 => "2KI",
      13 => "1CH", 14 => "2CH", 15 => "EZR", 16 => "NEH", 17 => "EST",
      18 => "JOB", 19 => "PSA", 20 => "PRO", 21 => "ECC", 22 => "SNG",
      23 => "ISA", 24 => "JER", 25 => "LAM", 26 => "EZK", 27 => "DAN",
      28 => "HOS", 29 => "JOL", 30 => "AMO", 31 => "OBA",
      32 => "JON", 33 => "MIC", 34 => "NAM", 35 => "HAB",
      36 => "ZEP", 37 => "HAG", 38 => "ZEC", 39 => "MAL",
      40 => "MAT", 41 => "MRK", 42 => "LUK", 43 => "JHN", 44 => "ACT",
      45 => "ROM", 46 => "1CO", 47 => "2CO", 48 => "GAL", 49 => "EPH",
      50 => "PHP", 51 => "COL", 52 => "1TH", 53 => "2TH",
      54 => "1TI", 55 => "2TI", 56 => "TIT", 57 => "PHM",
      58 => "HEB", 59 => "JAS", 60 => "1PE", 61 => "2PE",
      62 => "1JN", 63 => "2JN", 64 => "3JN", 65 => "JUD", 66 => "REV"
    }.freeze

    # Keep backward compatibility
    HEBREW_BOOK_NUMBERS = BOOK_NUMBERS

    def source_url
      "local:tmp/macula-{hebrew,greek}/*/lowfat"
    end

    def perform
      wipe_previous!

      @wu_cache = {}
      @word_cache = {}
      @batch = []

      import_hebrew if HEBREW_DIR.exist?
      import_greek if GREEK_DIR.exist?

      flush_batch!
      Rails.logger.info "[MaculaParticipants] Done: #{@stats}"
    end

    private

    def wipe_previous!
      old_runs = ImportRun.where(importer_class: self.class.name).where.not(id: @import_run.id).pluck(:id)
      ParticipantReference.where(import_run_id: old_runs).delete_all if old_runs.any?
    end

    def import_hebrew
      @work = Work.find_by!(slug: "wlc")
      files = Dir.glob(HEBREW_DIR.join("*.xml")).sort
      Rails.logger.info "[MaculaParticipants] Processing #{files.size} Hebrew files"

      files.each do |path|
        doc = Nokogiri::XML(File.read(path))
        doc.css("w").each { |w| process_word(w) }
      end
    end

    def import_greek
      @work = Work.find_by!(slug: "nestle1904")
      files = Dir.glob(GREEK_DIR.join("*.xml")).sort
      Rails.logger.info "[MaculaParticipants] Processing #{files.size} Greek files"

      files.each do |path|
        doc = Nokogiri::XML(File.read(path))
        doc.css("w").each { |w| process_word(w) }
      end
    end

    def process_word(w_el)
      ref = w_el["ref"]
      return unless ref

      source_pos = ref.split("!").last.to_i
      citation = parse_ref_citation(ref)
      return unless citation

      wu_id = find_wu_id(citation)
      return unless wu_id

      # participantref: pronoun → antecedent
      pref = w_el["participantref"]
      if pref.present?
        pref.strip.split(/\s+/).each do |target_id|
          add_reference(wu_id, source_pos, target_id, "participant", w_el)
        end
      end

      # subjref: verb → implicit subject
      sref = w_el["subjref"]
      if sref.present?
        sref.strip.split(/\s+/).each do |target_id|
          add_reference(wu_id, source_pos, target_id, "subject", w_el)
        end
      end

      # frame: semantic roles A0 (agent), A1 (patient), A2 (secondary)
      frame = w_el["frame"]
      if frame.present?
        frame.scan(/(A\d):(\S+?);/).each do |role, target_ids|
          ref_type = case role
                     when "A0" then "frame_a0"
                     when "A1" then "frame_a1"
                     when "A2" then "frame_a2"
                     else next
                     end
          target_ids.split(/\s+/).each do |target_id|
            add_reference(wu_id, source_pos, target_id, ref_type, w_el)
          end
        end
      end
    end

    def add_reference(wu_id, source_pos, target_id, ref_type, w_el)
      # Resolve source word
      source_word_id = find_word_id(wu_id, source_pos)
      return unless source_word_id

      # Resolve target word from Macula ID
      target_word_id = resolve_macula_id(target_id)

      @batch << {
        word_id: source_word_id,
        referent_word_id: target_word_id,
        work_unit_id: wu_id,
        ref_type: ref_type,
        macula_source_id: w_el["{http://www.w3.org/XML/1998/namespace}id"],
        macula_target_id: target_id,
        import_run_id: @import_run.id,
        created_at: Time.current,
        updated_at: Time.current
      }

      bump :refs_created
      flush_batch! if @batch.size >= 5000
    end

    def flush_batch!
      return if @batch.empty?
      ParticipantReference.insert_all(@batch)
      @batch.clear
    end

    def resolve_macula_id(macula_id)
      # Hebrew ID: 12 digits BBCCCVVVWWWM (e.g. "010010010031")
      # Greek ID:  "n" + 11 digits nBBCCCVVVWWW (e.g. "n40001002014")
      # Both encode book(2), chapter(3), verse(3), word_pos(3)
      cleaned = macula_id.gsub(/\D/, "")
      return nil if cleaned.length < 11

      book_num = cleaned[0..1].to_i
      chapter = cleaned[2..4].to_i
      verse = cleaned[5..7].to_i
      word_pos = cleaned[8..10].to_i

      book_code = BOOK_NUMBERS[book_num]
      return nil unless book_code

      sbl = BOOK_MAP[book_code]
      return nil unless sbl

      citation = "#{sbl} #{chapter}:#{verse}"
      target_wu_id = find_wu_id(citation)
      return nil unless target_wu_id

      find_word_id(target_wu_id, word_pos)
    end

    def parse_ref_citation(ref)
      verse_ref = ref.split("!").first
      parts = verse_ref.strip.split(" ", 2)
      sbl = BOOK_MAP[parts[0]]
      return nil unless sbl
      "#{sbl} #{parts[1]}"
    end

    def find_wu_id(citation)
      key = "#{@work.id}:#{citation}"
      return @wu_cache[key] if @wu_cache.key?(key)

      id = WorkUnit.joins(:canonical_ref)
                   .where(work_id: @work.id)
                   .where("canonical_refs.sbl_citation = ?", citation)
                   .pick(:id)
      @wu_cache[key] = id
      id
    end

    def find_word_id(wu_id, position)
      key = "#{wu_id}:#{position}"
      return @word_cache[key] if @word_cache.key?(key)

      id = Word.where(work_unit_id: wu_id, position: position).pick(:id)
      @word_cache[key] = id
      id
    end
  end
end
