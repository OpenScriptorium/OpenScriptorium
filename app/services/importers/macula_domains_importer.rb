require "nokogiri"

module Importers
  class MaculaDomainsImporter < BaseImporter
    HEBREW_DIR = Rails.root.join("tmp/macula-hebrew/WLC/lowfat")
    GREEK_DIR  = Rails.root.join("tmp/macula-greek/Nestle1904/lowfat")

    BOOK_MAP = MaculaSyntaxImporter::BOOK_MAP

    def source_url
      "local:tmp/macula-{hebrew,greek}/*/lowfat"
    end

    def perform
      @updates = []
      @wu_cache = {}

      import_from_dir(HEBREW_DIR, "wlc") if HEBREW_DIR.exist?
      import_from_dir(GREEK_DIR, "nestle1904") if GREEK_DIR.exist?

      flush_updates!
      Rails.logger.info "[MaculaDomains] Done: #{@stats[:words_updated]} words updated"
    end

    private

    def import_from_dir(dir, work_slug)
      @work = Work.find_by!(slug: work_slug)
      files = Dir.glob(dir.join("*.xml")).sort
      Rails.logger.info "[MaculaDomains] Processing #{files.size} files for #{work_slug}"

      files.each do |path|
        doc = Nokogiri::XML(File.read(path))
        doc.css("w").each do |w|
          sdbh = w["sdbh"]
          lexdomain = w["lexdomain"]
          coredomain = w["coredomain"]
          next unless sdbh || lexdomain || coredomain

          ref = w["ref"]
          next unless ref

          # Parse ref: "GEN 1:1!2" → citation "Gen 1:1", position 2
          parts = ref.split("!")
          position = parts[1]&.to_i
          verse_ref = parts[0]
          next unless position && position > 0

          citation = parse_citation(verse_ref)
          next unless citation

          wu_id = find_work_unit_id(citation)
          next unless wu_id

          @updates << {
            work_unit_id: wu_id,
            position: position,
            sdbh: sdbh,
            lexdomain: lexdomain,
            coredomain: coredomain
          }

          bump :words_scanned
          flush_updates! if @updates.size >= 5000
        end
      end
    end

    def flush_updates!
      return if @updates.empty?

      # Build bulk UPDATE using CASE
      @updates.each_slice(2000) do |slice|
        sdbh_cases = []
        lex_cases = []
        core_cases = []
        where_pairs = []

        slice.each do |u|
          cond = "WHEN work_unit_id = #{u[:work_unit_id]} AND position = #{u[:position]} THEN"
          sdbh_cases << "#{cond} #{u[:sdbh] ? ApplicationRecord.connection.quote(u[:sdbh]) : 'NULL'}"
          lex_cases << "#{cond} #{u[:lexdomain] ? ApplicationRecord.connection.quote(u[:lexdomain]) : 'NULL'}"
          core_cases << "#{cond} #{u[:coredomain] ? ApplicationRecord.connection.quote(u[:coredomain]) : 'NULL'}"
          where_pairs << "(#{u[:work_unit_id]}, #{u[:position]})"
        end

        ApplicationRecord.connection.execute(<<~SQL)
          UPDATE words SET
            sdbh = CASE #{sdbh_cases.join(" ")} ELSE sdbh END,
            lexdomain = CASE #{lex_cases.join(" ")} ELSE lexdomain END,
            coredomain = CASE #{core_cases.join(" ")} ELSE coredomain END
          WHERE (work_unit_id, position) IN (#{where_pairs.join(", ")})
        SQL

        bump :words_updated, slice.size
      end

      @updates.clear
    end

    def parse_citation(verse_ref)
      parts = verse_ref.strip.split(" ", 2)
      sbl = BOOK_MAP[parts[0]]
      return nil unless sbl
      "#{sbl} #{parts[1]}"
    end

    def find_work_unit_id(citation)
      return @wu_cache[citation] if @wu_cache.key?(citation)

      id = WorkUnit.joins(:canonical_ref)
                   .where(work_id: @work.id)
                   .where("canonical_refs.sbl_citation = ?", citation)
                   .pick(:id)
      @wu_cache[citation] = id
      id
    end
  end
end
