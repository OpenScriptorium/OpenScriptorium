class CreateWorks < ActiveRecord::Migration[8.1]
  # A "work" is anything with text in the corpus: a scripture translation,
  # an original-language scripture text, a commentary, a treatise, a
  # lexicon, etc. Single polymorphic table with a work_type enum.
  def change
    create_table :works do |t|
      t.string  :slug,                            null: false
      t.string  :title,                           null: false
      t.string  :native_title
      t.string  :work_type,                       null: false
        # scripture_translation, scripture_original, commentary,
        # treatise, letter, lexicon, pseudepigraphon, apocalypse,
        # apostolic_father, ...
      t.string  :language                # BCP-47 (e.g. "en", "he", "el-koine")
      t.string  :era                     # e.g. "1st century BCE"
      t.string  :tradition               # jewish, patristic, reformation, quaker, ...
      t.string  :genre

      t.references :license,             null: false, foreign_key: true
      t.references :default_versification_scheme,
                   foreign_key: { to_table: :versification_schemes }

      t.string  :source_url
      t.text    :import_notes
      t.integer :publication_year
      t.text    :description

      t.boolean :has_word_data,          null: false, default: false
      t.boolean :has_apparatus,          null: false, default: false

      t.datetime :imported_at
      t.datetime :last_imported_at
      t.string   :source_revision

      t.timestamps
    end

    add_index :works, :slug, unique: true
    add_index :works, :work_type
    add_index :works, :language
    add_index :works, :tradition
  end
end
