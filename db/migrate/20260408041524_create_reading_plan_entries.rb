class CreateReadingPlanEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :reading_plan_entries do |t|
      t.references :reading_plan,   null: false, foreign_key: true
      t.integer    :day,            null: false
      t.integer    :position,       null: false, default: 0
      t.references :canonical_work, null: false, foreign_key: true
      t.string     :label
      t.timestamps
    end

    execute <<~SQL
      ALTER TABLE reading_plan_entries ADD COLUMN canonical_range int4range NOT NULL;
    SQL

    add_index :reading_plan_entries, [:reading_plan_id, :day, :position], unique: true,
              name: "idx_rp_entries_order"
  end
end
