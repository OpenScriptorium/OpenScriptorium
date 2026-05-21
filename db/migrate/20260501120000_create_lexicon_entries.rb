class CreateLexiconEntries < ActiveRecord::Migration[8.1]
  # Rich lexicon entries (BDB, LSJ, Thayer, ISBE, etc.) tied to lemmas.
  # Distinct from the small `lemmas.senses` jsonb (which carries the
  # short scraped sense list) — these are full lexicon articles with
  # formatted body, citations, and source-specific metadata.
  #
  # `source` partitions entries by lexicon (BDB, LSJ, Thayer…) so a
  # single lemma can carry several entries from different traditions.
  # `body_html` holds the rendered article (sanitized HTML preserving
  # structural senses + citations + cross-refs from the source XML).
  #
  # `lemma_id` is nullable: not every lexicon entry will match a lemma
  # in our corpus (LSJ has classical-only Greek vocabulary that never
  # appears in the LXX/NT). Such entries stay browsable via headword
  # but don't surface on lemma pages until a matching lemma exists.

  def change
    create_table :lexicon_entries do |t|
      t.string :source, null: false
      t.references :lemma, foreign_key: true
      t.string :headword, null: false
      t.string :normalized
      t.string :transliteration
      t.string :part_of_speech
      t.string :summary_gloss
      t.text :body_html
      t.jsonb :citations, default: []
      t.jsonb :meta, default: {}
      t.references :license, foreign_key: true
      t.references :import_run, foreign_key: true
      t.timestamps
    end

    add_index :lexicon_entries, [:source, :headword], name: "idx_lexicon_entries_by_source_headword"
    add_index :lexicon_entries, [:source, :normalized], name: "idx_lexicon_entries_by_source_normalized"
    add_index :lexicon_entries, [:lemma_id, :source], name: "idx_lexicon_entries_by_lemma_source"
  end
end
