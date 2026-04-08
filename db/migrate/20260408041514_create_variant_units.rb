class CreateVariantUnits < ActiveRecord::Migration[8.1]
  # A "variant unit" is a place in the text where witnesses disagree.
  # It belongs to a canonical_ref and points at a base reading.
  def change
    create_table :variant_units do |t|
      t.references :canonical_ref,  null: false, foreign_key: true
      t.integer    :position_within_ref, null: false, default: 1
      t.bigint     :base_reading_id    # FK added after readings table exists
      t.text       :notes
      t.timestamps
    end

    add_index :variant_units, [:canonical_ref_id, :position_within_ref], unique: true
  end
end
