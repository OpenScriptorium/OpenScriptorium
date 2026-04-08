class CreateReadings < ActiveRecord::Migration[8.1]
  # A reading is one specific textual variant at a variant_unit.
  def change
    create_table :readings do |t|
      t.references :variant_unit, null: false, foreign_key: true
      t.text       :text,            null: false
      t.text       :normalized_text
      t.text       :notes
      t.boolean    :is_base, null: false, default: false
      t.timestamps
    end

    add_index :readings, [:variant_unit_id, :is_base]

    # Now that readings exists, attach the base_reading_id FK on
    # variant_units.
    add_foreign_key :variant_units, :readings, column: :base_reading_id
    add_index :variant_units, :base_reading_id
  end
end
