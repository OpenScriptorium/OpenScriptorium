class EnrichVariantUnits < ActiveRecord::Migration[8.1]
  # Adds the lemma_text + context fields critical editions need to make
  # an apparatus entry actually readable.
  #
  # In a critical apparatus you read:
  #
  #     Mark 1:1 — υἱοῦ θεοῦ ] om. ℵ* Θ 28c sa^ms
  #
  # `υἱοῦ θεοῦ` is the LEMMA TEXT — the disputed phrase being commented on.
  # Without storing it explicitly, the apparatus is unreadable. context_before
  # and context_after disambiguate when the same word occurs multiple times
  # in a verse.
  def change
    change_table :variant_units do |t|
      t.text :lemma_text                       # the disputed phrase
      t.text :context_before                   # words preceding the lemma
      t.text :context_after                    # words following the lemma
      t.string :variant_type                   # substitution, omission, addition, transposition, orthographic
    end
  end
end
