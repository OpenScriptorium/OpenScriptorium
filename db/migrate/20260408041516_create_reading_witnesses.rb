class CreateReadingWitnesses < ActiveRecord::Migration[8.1]
  # Which manuscripts attest which readings.
  def change
    create_table :reading_witnesses do |t|
      t.references :reading,    null: false, foreign_key: true
      t.references :manuscript, null: false, foreign_key: true
      t.string     :certainty   # certain, probable, possible, doubtful
      t.text       :notes
      t.timestamps
    end

    add_index :reading_witnesses, [:reading_id, :manuscript_id], unique: true
  end
end
