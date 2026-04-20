class CreatePassageAliases < ActiveRecord::Migration[8.1]
  def change
    create_table :passage_aliases do |t|
      t.string :ref, null: false
      t.bigint :import_run_id
      t.timestamps
      t.index :import_run_id
    end

    create_table :passage_alias_names do |t|
      t.references :passage_alias, null: false, foreign_key: true
      t.string :name, null: false
      t.string :locale, default: "en"
      t.timestamps
      t.index "LOWER(name)", name: "idx_passage_alias_names_lower"
      t.index "LOWER(name) gin_trgm_ops", using: :gin, name: "idx_passage_alias_names_trgm"
    end
  end
end
