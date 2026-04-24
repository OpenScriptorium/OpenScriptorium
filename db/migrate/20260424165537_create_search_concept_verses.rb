class CreateSearchConceptVerses < ActiveRecord::Migration[8.1]
  # Link table: concept → canonical_ref with a role and per-pair weight.
  # `role` captures what the verse is TO the concept (signature climax,
  # supporting context, a famous quote from it) so the strategy can
  # prefer signature verses and demote context-only hits.
  # `weight` is a per-pair boost multiplier (default 1.0; curators can
  # tune up to ~3.0 for an extra-strong signature pair).

  def change
    create_table :search_concept_verses do |t|
      t.references :search_concept, null: false, foreign_key: { on_delete: :cascade }
      t.references :canonical_ref, null: false, foreign_key: true
      t.string :role, null: false, default: "signature"
      t.decimal :weight, precision: 4, scale: 2, null: false, default: 1.0
      t.references :import_run, foreign_key: true
      t.timestamps
    end

    add_index :search_concept_verses,
      [:search_concept_id, :canonical_ref_id],
      unique: true, name: "idx_concept_verses_unique"
  end
end
