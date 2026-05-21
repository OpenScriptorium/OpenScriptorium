class DropLemmaUniqueIndexForHomonyms < ActiveRecord::Migration[8.1]
  # The (language, lemma) unique index can't accommodate Hebrew (and
  # occasionally Greek) homonyms that share a consonantal skeleton but
  # represent different lexemes — e.g. נֵר is both H5216 "lamp" (common
  # noun) and H5369 "Ner" (the man); H4194 מָוֶת "death" and the place
  # H1120 בָּמוֹת share related Strong's that StepLexicon collapses to
  # the same headword. With the unique index in place these end up
  # merged onto one row, the lemma popover shows one gloss for both
  # senses, and corpus-wide searches conflate them.
  #
  # Replace the unique index with a plain btree on the same columns
  # so lookups stay fast but multiple rows for the same headword are
  # allowed. Disambiguation is done at the Word level: each Word's
  # strongs_number is the discriminator.
  def up
    remove_index :lemmas, name: "index_lemmas_on_language_and_lemma"
    add_index :lemmas, [:language, :lemma], name: "index_lemmas_on_language_and_lemma"
  end

  def down
    # Going back to a unique index is unsafe once homonyms are split.
    raise ActiveRecord::IrreversibleMigration
  end
end
