class CreatePericopes < ActiveRecord::Migration[8.1]
  # Named passage groupings — pericopes, parashot/sedarim, lectionary
  # readings, chapter-headings-from-translations, etc. Stored at the
  # canonical layer (not per-work) so a pericope name applies to every
  # translation of the same passage.
  #
  # source_dataset lets us hold MULTIPLE pericope schemes simultaneously
  # — e.g. BHS pericope structure, NRSV section headings, the Revised
  # Common Lectionary, the Triennial Cycle of Torah readings, the
  # Migne PG editorial pericopes for patristic texts.
  #
  # Range stored as int4range over canonical_refs.ord with GIST index
  # for fast "what pericope is this verse in?" queries.
  def change
    create_table :pericopes do |t|
      t.references :canonical_work, null: false, foreign_key: true
      t.string :source_dataset,     null: false
        # 'BHS', 'NRSV', 'RCL', 'Triennial', 'Migne-PG', 'translator-headings', ...
      t.string :name,               null: false
      t.string :native_name                      # in the work's language if applicable
      t.string :pericope_type                    # 'pericope', 'parashah', 'haftarah', 'lectionary', 'heading'
      t.integer :sequence_number                 # ordering within the dataset
      t.text   :description
      t.references :import_run, foreign_key: true
      t.timestamps
    end

    execute <<~SQL
      ALTER TABLE pericopes ADD COLUMN canonical_range int4range NOT NULL;
      CREATE INDEX idx_pericopes_range
        ON pericopes USING gist (canonical_work_id, canonical_range);
    SQL

    add_index :pericopes, :source_dataset
    add_index :pericopes, [:source_dataset, :sequence_number]
    add_index :pericopes, :pericope_type
  end
end
