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
  def up
    %w[
      fk_rails_fca994b121
      fk_rails_24c37b6850
      fk_rails_2abc28faff
    ].each do |fk|
      execute "ALTER TABLE public.#{fk_table(fk)} DROP CONSTRAINT #{fk}"
    end

    add_foreign_key :participant_references, :words, column: :word_id, on_delete: :cascade
    add_foreign_key :participant_references, :words, column: :referent_word_id, on_delete: :cascade
    add_foreign_key :alignment_group_members, :words, column: :word_id, on_delete: :cascade
  end

  def down
    remove_foreign_key :participant_references, column: :word_id
    remove_foreign_key :participant_references, column: :referent_word_id
    remove_foreign_key :alignment_group_members, column: :word_id

    add_foreign_key :participant_references, :words, column: :word_id
    add_foreign_key :participant_references, :words, column: :referent_word_id
    add_foreign_key :alignment_group_members, :words, column: :word_id
  end

  private

  def fk_table(fk_name)
    case fk_name
    when "fk_rails_fca994b121", "fk_rails_24c37b6850" then "participant_references"
    when "fk_rails_2abc28faff" then "alignment_group_members"
    end
  end
end
