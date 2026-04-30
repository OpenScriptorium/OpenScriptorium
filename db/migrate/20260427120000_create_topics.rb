class CreateTopics < ActiveRecord::Migration[8.1]
  # Topical themes from external datasets (OpenBible.info Topics, Sefaria
  # Topics, etc.) modeled as a generic two-level structure independent of
  # any specific source. Each `topic` is a named theme from a single source;
  # each `topic_verse` is a (topic, canonical_ref) pair with a source-
  # specific relevance score. Importers de-duplicate when the same source
  # row references a verse range — the highest source_rank wins on conflict.
  #
  # `source` partitions topics by dataset ("openbible_topics", "sefaria_topics")
  # so a user-preference toggle can enable/disable each independently.

  def change
    create_table :topics do |t|
      t.string :source, null: false
      t.string :source_topic_id, null: false
      t.string :name, null: false
      t.string :display_name
      t.text :description
      t.string :category
      t.references :license, foreign_key: true
      t.references :import_run, foreign_key: true
      t.timestamps
    end

    add_index :topics, [:source, :source_topic_id], unique: true
    add_index :topics, :name
    add_index :topics, :source

    create_table :topic_verses do |t|
      t.references :topic, null: false, foreign_key: { on_delete: :cascade }
      t.references :canonical_ref, null: false, foreign_key: true
      t.float :source_rank, null: false
      t.references :import_run, foreign_key: true
      t.timestamps
    end

    add_index :topic_verses,
      [:topic_id, :canonical_ref_id],
      unique: true, name: "idx_topic_verses_unique"
    add_index :topic_verses,
      [:topic_id, :source_rank],
      order: { source_rank: :desc },
      name: "idx_topic_verses_by_rank"
  end
end
