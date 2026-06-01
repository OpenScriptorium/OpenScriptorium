class AddLsjFieldsToLemmas < ActiveRecord::Migration[8.1]
  # Homonym disambiguation for Greek lemmas using the LSJ key suffix
  # convention. Headwords like λέγω, ὁ, καί appear as multiple distinct
  # entries in LSJ (e.g. "le/gw1" = collect, "le/gw2" = say); each LSJ
  # entry becomes its own Lemma row, indexed by homonym_n + lsj_key.
  #
  # homonym_n  defaults to 1 for non-ambiguous headwords; 2,3,… mark
  #            additional entries for the same surface form.
  # lsj_key    stores the raw Perseus key ("le/gw2") so an entry can be
  #            re-found across re-imports and linked to a citation URL.
  def change
    add_column :lemmas, :homonym_n, :integer
    add_column :lemmas, :lsj_key,   :string

    add_index :lemmas, [:language, :lemma, :homonym_n],
              unique: true,
              where: "homonym_n IS NOT NULL",
              name:  "index_lemmas_unique_homonym"
    add_index :lemmas, :lsj_key, unique: true, where: "lsj_key IS NOT NULL"
  end
end
