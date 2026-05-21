class CascadeWordDependents < ActiveRecord::Migration[8.1]
  # When BsbTables (and any other importer) re-runs a verse it deletes
  # the verse's words and reinserts them. Without ON DELETE CASCADE on
  # tables that FK into words.id, that delete fails:
  #
  #   participant_references.word_id          (Macula coreference data)
  #   participant_references.referent_word_id (Macula coreference targets)
  #   alignment_group_members.word_id         (Macula syntax alignments)
  #
  # All three reference a specific word's identity — when the word is
  # deleted, those rows are meaningless and should go with it.
  #
  # Look up FK names dynamically by (table, column) since Rails-generated
  # FK hash suffixes differ across environments (dev DBs were created at
  # different times than the prod DB).
  TARGETS = [
    [:participant_references, :word_id],
    [:participant_references, :referent_word_id],
    [:alignment_group_members, :word_id]
  ].freeze

  def up
    TARGETS.each do |table, column|
      remove_foreign_key table, column: column if foreign_key_exists?(table, column: column)
      add_foreign_key table, :words, column: column, on_delete: :cascade
    end
  end

  def down
    TARGETS.each do |table, column|
      remove_foreign_key table, column: column if foreign_key_exists?(table, column: column)
      add_foreign_key table, :words, column: column
    end
  end
end
