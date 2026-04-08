class CreateCanonicalWorks < ActiveRecord::Migration[8.1]
  # The abstract concept of a text — "Genesis", "Gospel of Matthew",
  # "Josephus, Antiquities Bk 1", "Gospel of Thomas". Translations and
  # editions of the same underlying text align to this layer through
  # work_units.canonical_ref_id.
  def change
    create_table :canonical_works do |t|
      t.string  :slug,                       null: false
      t.string  :title,                      null: false
      t.string  :native_title
      t.references :versification_scheme,    foreign_key: true
      t.references :parent_canonical_work,   foreign_key: { to_table: :canonical_works }
      t.integer :position
      t.string  :testament              # ot, nt, deuterocanon, pseudepigrapha, apostolic_father, ...
      t.string  :osis_book_id           # e.g. "Gen", "Matt" — for OSIS-compatible texts
      t.text    :description
      t.timestamps
    end

    add_index :canonical_works, :slug, unique: true
    add_index :canonical_works, :testament
    add_index :canonical_works, :osis_book_id
    add_index :canonical_works, [:parent_canonical_work_id, :position]
  end
end
