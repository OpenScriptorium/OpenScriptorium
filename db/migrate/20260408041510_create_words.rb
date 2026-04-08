class CreateWords < ActiveRecord::Migration[8.1]
  # Word-level data for original-language texts (Hebrew Bible, Greek NT,
  # LXX). Each inflected word in a verse becomes a row, FK'd to its
  # lemma. Used for interlinear display, concordance, alignment.
  def change
    create_table :words do |t|
      t.references :work,      null: false, foreign_key: true
      t.references :work_unit, null: false, foreign_key: true
      t.integer    :position,  null: false  # word order within the unit
      t.string     :surface,   null: false  # inflected form as it appears
      t.string     :normalized                # without pointing/breathing/accents
      t.references :lemma,     foreign_key: true
      t.string     :morph_code                # POS + parsing in tradition's notation
      t.string     :strongs_number
      t.jsonb      :notes, default: {}, null: false
      t.timestamps
    end

    add_index :words, [:work_unit_id, :position]
    add_index :words, :strongs_number
  end
end
