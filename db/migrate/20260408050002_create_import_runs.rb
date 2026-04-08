class CreateImportRuns < ActiveRecord::Migration[8.1]
  # Per-import-run provenance. Every importer run gets a row here, and
  # every row of imported data is stamped with the import_run_id that
  # created or last touched it. Pairs with PaperTrail to give us:
  #
  #   * "what changed"     (PaperTrail)
  #   * "which import did" (import_runs)
  #
  # Together that's everything reproducible-research needs from the data
  # provenance side. Backfilling later would mean walking 750k word rows
  # without knowing where each came from, so this MUST exist before the
  # big imports.
  def change
    create_table :import_runs do |t|
      t.string  :importer_class,    null: false
      t.string  :source_url
      t.string  :source_revision               # sha, mtime, version string
      t.bigint  :source_byte_count
      t.string  :source_format                  # 'tsv', 'osis', 'xml', 'json'
      t.datetime :started_at,        null: false
      t.datetime :finished_at
      t.string  :status,             null: false, default: "running"
        # running, completed, failed, aborted
      t.text    :error_message
      t.text    :error_backtrace
      t.jsonb   :stats,              null: false, default: {}
        # importer-specific counters: rows_in, rows_out, units_created,
        # words_created, lemmas_created, etc.
      t.jsonb   :options,            null: false, default: {}
        # the importer's invocation options for reproducibility
      t.timestamps
    end

    add_index :import_runs, :importer_class
    add_index :import_runs, :status
    add_index :import_runs, :started_at

    # Stamp every row in every importable table with the run that
    # produced it. All nullable so backfill / pre-existing rows are OK.
    importable_tables = %w[
      works
      work_units
      canonical_refs
      words
      lemmas
      alignment_groups
      alignment_group_members
      manuscripts
      variant_units
      readings
      reading_witnesses
      cross_references
    ]

    importable_tables.each do |t|
      add_reference t.to_sym, :import_run, foreign_key: true
    end
  end
end
