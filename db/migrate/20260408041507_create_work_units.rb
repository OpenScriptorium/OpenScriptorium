class CreateWorkUnits < ActiveRecord::Migration[8.1]
  # The smallest addressable piece of any work — a verse, a Loeb section,
  # a logion, a paragraph. work_units.canonical_ref_id aligns translations
  # and editions to the abstract canonical layer.
  def change
    create_table :work_units do |t|
      t.references :work,           null: false, foreign_key: true
      t.integer    :ord,            null: false  # sequential within work
      t.references :parent,         foreign_key: { to_table: :work_units }
      t.integer    :position                      # sibling order within parent
      t.string     :label                          # display label "1:1", "1.1.1", "Logion 22"
      t.string     :hierarchy_path                 # ltree path for breadcrumb queries

      t.references :canonical_ref,  foreign_key: true
      t.string     :canonical_alignment_type, default: "exact"
        # exact, approximate, ambiguous, none
      t.decimal    :canonical_alignment_confidence, precision: 4, scale: 3

      t.text       :body                           # plain-text body for fast display + FTS
      t.jsonb      :markup, default: {}, null: false
        # USFM-like markers: paragraph breaks, poetry indent, headings,
        # speaker labels, footnote anchors, divine name styling, red letter

      t.timestamps
    end

    add_index :work_units, [:work_id, :ord], unique: true
    add_index :work_units, [:parent_id, :position]
  end
end
