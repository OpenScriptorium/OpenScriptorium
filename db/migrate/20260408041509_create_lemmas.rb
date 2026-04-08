class CreateLemmas < ActiveRecord::Migration[8.1]
  # Lexical entries (Hebrew, Greek, etc). Word rows FK to a lemma so we
  # can answer "all occurrences of רֵאשִׁית" with one indexed query.
  # The lexicon_entry_id optionally points at a work_unit in a lexicon
  # work (BDB, LSJ, etc.) for "tap to see full definition".
  def change
    create_table :lemmas do |t|
      t.string  :language,      null: false  # he, el-koine, la, ...
      t.string  :lemma,         null: false  # lexical form (with pointing)
      t.string  :normalized,    null: false  # without pointing/breathing/accents
      t.string  :primary_gloss
      t.string  :part_of_speech
      t.integer :frequency,     null: false, default: 0
      t.references :lexicon_entry, foreign_key: { to_table: :work_units }
      t.timestamps
    end

    add_index :lemmas, [:language, :normalized]
    add_index :lemmas, [:language, :lemma], unique: true
  end
end
