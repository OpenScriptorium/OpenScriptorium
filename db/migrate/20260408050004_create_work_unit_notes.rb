class CreateWorkUnitNotes < ActiveRecord::Migration[8.1]
  # First-class translator and editor notes attached to a work_unit.
  #
  # Critical translations have multiple kinds of notes:
  #
  #   textual       — "some manuscripts read X" / "literally Y"
  #   translation   — "or 'spirit'" / "the Greek means..."
  #   cross_reference — "see Heb 11:3"
  #   explanation   — "a Hebrew unit of weight equal to..."
  #   editorial     — "the original text is uncertain here"
  #
  # If we shove these into work_units.markup we lose the ability to
  # query "all text-critical notes in BSB". Make them first-class.
  def change
    create_table :work_unit_notes do |t|
      t.references :work_unit,    null: false, foreign_key: true
      t.references :import_run,   foreign_key: true

      t.integer :position_in_unit, null: false, default: 0
        # ordering when a single verse has multiple notes

      t.string :note_type, null: false
        # textual, translation, cross_reference, explanation, editorial

      t.text :body,        null: false        # the note's text content
      t.text :anchor_text                      # the word/phrase the note is about

      t.timestamps
    end

    add_index :work_unit_notes, [:work_unit_id, :position_in_unit]
    add_index :work_unit_notes, :note_type
  end
end
