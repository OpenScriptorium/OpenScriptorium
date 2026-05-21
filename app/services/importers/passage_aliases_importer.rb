require "json"

module Importers
  class PassageAliasesImporter < BaseImporter
    # Curated list of named passages (Creation Account, Sermon on the
    # Mount, Magnificat, etc.). The data is hand-edited and shipped in
    # the repo at db/seeds/passage_aliases/combined.json — that file is
    # the source of truth, NOT a downstream tmp/ file.
    SEED_DIR = Rails.root.join("db/seeds/passage_aliases")

    FILES = %w[
      pentateuch.json
      historical.json
      wisdom.json
      prophets.json
      gospels.json
      acts_epistles_rev.json
      deuterocanon.json
    ].freeze

    def source_url
      "https://github.com/seth/openscriptorium/tree/master/db/seeds/passage_aliases"
    end

    def perform
      wipe_previous_run!

      entries = load_entries
      Rails.logger.info "Loaded #{entries.size} entries with #{entries.sum { |e| e['names'].size }} aliases"

      batch_aliases = []
      batch_names = []

      entries.each_with_index do |entry, idx|
        ref = entry["ref"]
        names = entry["names"]
        next if ref.blank? || names.blank?

        pa = PassageAlias.new(ref: ref, import_run: @import_run)
        batch_aliases << pa

        names.each do |name|
          next if name.blank?
          locale = detect_locale(name)
          batch_names << { alias_index: idx, name: name, locale: locale }
        end

        bump :entries
      end

      # Bulk insert aliases
      Rails.logger.info "Inserting #{batch_aliases.size} passage aliases..."
      PassageAlias.insert_all(
        batch_aliases.map { |pa| { ref: pa.ref, import_run_id: @import_run.id, created_at: Time.current, updated_at: Time.current } },
        returning: [:id]
      )

      # Fetch back IDs in insertion order
      alias_ids = PassageAlias.where(import_run_id: @import_run.id).order(:id).pluck(:id)

      # Bulk insert names
      Rails.logger.info "Inserting #{batch_names.size} alias names..."
      name_rows = batch_names.map do |bn|
        {
          passage_alias_id: alias_ids[bn[:alias_index]],
          name: bn[:name],
          locale: bn[:locale],
          created_at: Time.current,
          updated_at: Time.current
        }
      end

      name_rows.each_slice(5000) do |slice|
        PassageAliasName.insert_all(slice)
      end

      Rails.logger.info "Done: #{alias_ids.size} aliases, #{name_rows.size} names"
    end

    private

    def load_entries
      combined_path = SEED_DIR.join("combined.json")
      if combined_path.exist?
        JSON.parse(File.read(combined_path))
      else
        FILES.flat_map do |f|
          path = SEED_DIR.join(f)
          next [] unless path.exist?
          JSON.parse(File.read(path))
        end
      end
    end

    def wipe_previous_run!
      old_ids = PassageAlias.where(import_run_id: @import_run&.id).pluck(:id)
      if old_ids.any?
        PassageAliasName.where(passage_alias_id: old_ids).delete_all
        PassageAlias.where(id: old_ids).delete_all
      end
      # Also wipe any previous import
      old_runs = ImportRun.where(importer_class: self.class.name).where.not(id: @import_run.id).pluck(:id)
      if old_runs.any?
        old_alias_ids = PassageAlias.where(import_run_id: old_runs).pluck(:id)
        PassageAliasName.where(passage_alias_id: old_alias_ids).delete_all if old_alias_ids.any?
        PassageAlias.where(import_run_id: old_runs).delete_all
      end
    end

    def detect_locale(name)
      if name.match?(/[\u0590-\u05FF]/)
        "he"
      elsif name.match?(/[\u0370-\u03FF\u1F00-\u1FFF]/)
        "grc"
      elsif name.match?(/\b(Parashat|Shir|Birkat|Bereshit|Vayikra|Bamidbar|Devarim|Shemot|HaShavua|Mah Tovu|Hinei|Ashrei)\b/)
        "he"
      elsif name.match?(/\b(Fiat|Imago|Magnificat|Benedictus|Nunc Dimittis|Miserere|Venite|Jubilate|Dixit|Pater Noster|Magna Est|Requiem)\b/i)
        "la"
      else
        "en"
      end
    end
  end
end
