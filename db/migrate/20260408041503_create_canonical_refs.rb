class CreateCanonicalRefs < ActiveRecord::Migration[8.1]
  # The smallest abstract addressable unit within a canonical_work.
  # For Genesis: one row per verse (e.g. Gen 1:1 → ord=1, hierarchy=[1,1]).
  # For Gospel of Thomas: one row per logion. For Loeb-style commentary:
  # one row per (book, chapter, section) tuple.
  #
  # `ord` is sequential within the canonical_work and drives int4range
  # queries on cross_references via the GIST index.
  def change
    create_table :canonical_refs do |t|
      t.references :canonical_work, null: false, foreign_key: true
      t.integer    :ord,            null: false
      t.string     :display_label,  null: false  # "Gen 1:1", "Logion 22"
      t.string     :osis_id                       # "Gen.1.1" if applicable
      t.integer    :hierarchy, array: true, default: [], null: false
      t.timestamps
    end

    add_index :canonical_refs, [:canonical_work_id, :ord], unique: true
    add_index :canonical_refs, :hierarchy, using: :gin
    add_index :canonical_refs, :osis_id
  end
end
