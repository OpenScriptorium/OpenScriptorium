class CreateParticipantReferences < ActiveRecord::Migration[8.1]
  def change
    create_table :participant_references do |t|
      t.references :word, null: false, foreign_key: true        # the pronoun/verb
      t.references :referent_word, foreign_key: { to_table: :words } # what it refers to
      t.references :work_unit, null: false, foreign_key: true
      t.string     :ref_type, null: false  # "participant" (pronoun→antecedent), "subject" (verb→subject), "frame_a0" (agent), "frame_a1" (patient)
      t.string     :macula_source_id       # original Macula word ID for provenance
      t.string     :macula_target_id       # original Macula target ID
      t.bigint     :import_run_id
      t.timestamps

      t.index [:work_unit_id, :ref_type]
      t.index [:referent_word_id, :ref_type], name: "idx_participant_refs_referent"
      t.index :import_run_id
    end
  end
end
