class EnrichManuscripts < ActiveRecord::Migration[8.1]
  # Manuscript metadata for citation-grade reference.
  #
  # A scholar inspecting a witness reads things like:
  #
  #   "Codex Vaticanus, 4th c., Alexandrian text-type, Greek vellum
  #    codex, 759 folios, currently in Vatican Library shelfmark
  #    Vat.gr.1209, Gregory-Aland B/03, INTF Liste 03, includes most
  #    of OT and NT, lacks Genesis 1:1–46:28a, Psalms 105:27–137:6,
  #    Hebrews 9:14 to end."
  #
  # Most of this is fillable from the INTF Liste (CC BY-SA from Münster)
  # when we import witness data.
  def change
    change_table :manuscripts do |t|
      t.string :gregory_aland_number
        # canonical NT manuscript identifier (e.g. "01" for Sinaiticus,
        # "B/03" for Vaticanus, "P46" for Papyrus 46)
      t.string :intf_liste_number
        # the Münster INTF Kurzgefasste Liste number
      t.string :material
        # "vellum", "papyrus", "paper", "parchment"
      t.string :format
        # "codex", "scroll", "fragment", "ostracon"
      t.text   :extent_description
        # human-readable text about what books/parts the manuscript contains
      t.jsonb  :lacunae, null: false, default: []
        # [{canonical_work_slug: "genesis", from: [1,1], to: [46,28]}, ...]
      t.string :shelfmark
        # current library shelfmark, e.g. "Vat.gr.1209"
      # Note: import_run_id was already added on the manuscripts table by
      # the CreateImportRuns migration's stamping loop.
    end

    add_index :manuscripts, :gregory_aland_number
    add_index :manuscripts, :intf_liste_number
  end
end
