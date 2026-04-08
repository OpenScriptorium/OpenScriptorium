class CreateVersificationMappings < ActiveRecord::Migration[8.1]
  # Records divergences between versification schemes (mostly Psalms +
  # Jeremiah). E.g. MT Psalm 9 == LXX Psalm 9+10 (split). Defer to
  # Crosswire's published v11n tables; never invent ad-hoc mappings.
  def change
    create_table :versification_mappings do |t|
      t.references :from_scheme,        null: false, foreign_key: { to_table: :versification_schemes }
      t.references :from_canonical_ref, null: false, foreign_key: { to_table: :canonical_refs }
      t.references :to_scheme,          null: false, foreign_key: { to_table: :versification_schemes }
      t.references :to_canonical_ref,   null: false, foreign_key: { to_table: :canonical_refs }
      t.string     :mapping_type,       null: false  # exact, partial, split, merge, missing
      t.text       :notes
      t.timestamps
    end

    add_index :versification_mappings,
              [:from_scheme_id, :from_canonical_ref_id, :to_scheme_id],
              name: "idx_v11n_mappings_from"
    add_index :versification_mappings,
              [:to_scheme_id, :to_canonical_ref_id, :from_scheme_id],
              name: "idx_v11n_mappings_to"
  end
end
