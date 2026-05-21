class AddCanonicalLemmaIdToLemmas < ActiveRecord::Migration[8.1]
  # Self-FK pointing inflected-form lemmas to their dictionary-form lemma.
  #
  # Background: the corpus's text importers (BSB-tables, KJV-strongs,
  # Robinson-Pierpont, etc.) created `lemmas` rows keyed on the surface
  # form they encountered, so most "lemmas" are actually inflected forms
  # (αιτουντι, ανειλεν, באבו). The StepLexicon, BDB, and LSJ importers
  # create separate "dictionary-form" lemmas (αἰτέω, ἀναιρέω, אֵב) that
  # carry the lexicographic data (translit, gloss, senses, lexicon
  # entries) but typically have zero attached Words.
  #
  # `canonical_lemma_id` lets a Word's lemma_id point at an inflected-
  # form row while the popover / lemma page can fall through to the
  # dictionary-form row for the actual meaning data. NULL on dictionary
  # forms themselves (and on lemmas where no canonical was found).

  def change
    add_reference :lemmas, :canonical_lemma,
      foreign_key: { to_table: :lemmas },
      null: true, index: true
  end
end
