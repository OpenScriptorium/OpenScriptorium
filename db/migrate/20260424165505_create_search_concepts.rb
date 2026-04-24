class CreateSearchConcepts < ActiveRecord::Migration[8.1]
  # Curated concept → signature-verse mapping. Bridges natural-language
  # concepts ("the cross", "burning bush", "end times") to biblical
  # vocabulary so queries whose expected verse doesn't contain the query
  # keyword can still surface the right passage.
  #
  # `aliases` stores the phrases that should trigger a concept match.
  # `kind` classifies the concept (event, topic, title, …) for future
  # filtering and admin UI grouping.

  def change
    create_table :search_concepts do |t|
      t.string :name, null: false
      t.text :description
      t.text :aliases, array: true, null: false, default: []
      t.string :kind, null: false
      t.references :import_run, foreign_key: true
      t.timestamps
    end

    add_index :search_concepts, :name, unique: true
    add_index :search_concepts, :aliases, using: :gin
    add_index :search_concepts, :kind
  end
end
