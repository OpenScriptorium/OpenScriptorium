class EnrichLemmas < ActiveRecord::Migration[8.1]
  # Lexical metadata for serious lexicographic use.
  #
  # The thin lemma model (lemma + normalized + primary_gloss + frequency)
  # is fine for "click to define" hover. For real lexicography you also
  # need:
  #
  #   * etymology         — derivation chain
  #   * senses            — multiple meanings, each with attestations
  #   * related_lemmas    — synonyms, antonyms, cognates, derivatives
  #   * transliteration   — Hebrew/Greek romanization
  #   * frequency_by_book — distribution of attestations
  #
  # Most of these are fillable from STEPBible-Data, OpenScriptures
  # morphological tags, and BDB/LSJ when those imports happen.
  def change
    change_table :lemmas do |t|
      t.text  :etymology
      t.string :transliteration
      t.jsonb :senses,            null: false, default: []
        # [{gloss, part_of_speech, references[], frequency_in_sense}, ...]
      t.integer :related_lemma_ids, array: true, default: [], null: false
      t.jsonb :frequency_by_book, null: false, default: {}
        # { "Gen" => 12, "Exod" => 7, ... }
      t.string :attested_period
        # "biblical_hebrew", "second_temple", "rabbinic", "koine", "patristic"
      # Note: import_run_id was already added on the lemmas table by the
      # CreateImportRuns migration's stamping loop.
    end

    add_index :lemmas, :related_lemma_ids, using: :gin
  end
end
