class EnrichReadingWitnesses < ActiveRecord::Migration[8.1]
  # Real apparatus citations name the manuscript AND the corrector hand
  # AND the physical location within the manuscript:
  #
  #     ℵ²ᵃ          Sinaiticus, second corrector hand A
  #     B 16r col 2  Vaticanus, folio 16 recto, column 2
  #     𝔓46* mg      P46 original hand, marginal reading
  #
  # Plus apparatus entries often note when a reading is INFERRED because
  # the witness is damaged (lacuna) or supplied by a later hand.
  def change
    change_table :reading_witnesses do |t|
      # Corrector / hand layer. Stable but extensible vocabulary;
      # validated against ReadingWitness::CORRECTION_LAYERS in the model
      # rather than a Postgres enum so we can add values without DDL.
      # Examples: '*' (original), '1', '2', '3' (correctors),
      #           'c' (corrected), 'vid' (apparently),
      #           'mg' (margin), 'txt' (in text)
      t.string :correction_layer

      # Physical location within the witness. All optional — most
      # imports will only have folio level. column_number / line_number
      # named with _number suffix to avoid SQL "column" reserved word.
      t.string  :folio
      t.integer :column_number
      t.integer :line_number

      t.boolean :is_lacuna,    null: false, default: false
      t.boolean :is_supplement, null: false, default: false
    end
  end
end
