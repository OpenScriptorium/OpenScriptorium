class AddStableCitations < ActiveRecord::Migration[8.1]
  # Stable, citation-style identifiers that don't break if slugs change.
  # Designed to support the SBL Handbook of Style citation formats:
  #
  #   Scripture:    "Gen 1:1"           "Gen 1:1a"          "Rev 22:21"
  #   Loeb-style:   "Philo, QG 1.1"     "Josephus, Ant. 1.1.1"
  #   Logia:        "Gos. Thom. 22"     "Did. 1.1"
  #
  # The format depends on the canonical_work. We store the work's
  # SBL abbreviation and the format style; canonical_refs cache the
  # rendered citation string in sbl_citation for fast lookup and
  # consistent display.
  CITATION_FORMATS = %w[scripture hierarchical].freeze

  def change
    change_table :canonical_works do |t|
      # Short SBL-style abbreviation: "Gen", "Matt", "Philo, QG",
      # "Josephus, Ant.", "Gos. Thom.", "Did.", etc.
      t.string :sbl_abbreviation

      # How to render references for this work:
      #   "scripture":    {abbr} {1}:{2}[{part_letter}]
      #                   e.g. "Gen 1:1", "Gen 1:1a"
      #   "hierarchical": {abbr} {1}.{2}.{3}...
      #                   e.g. "Philo, QG 1.1", "Josephus, Ant. 1.1.1"
      t.string :citation_format, default: "scripture"
    end

    change_table :canonical_refs do |t|
      # Cached SBL-style citation string. Computed on save by the model
      # from canonical_work.sbl_abbreviation + hierarchy. Indexed for
      # fast permalink lookup.
      t.string :sbl_citation
    end

    add_index :canonical_refs, :sbl_citation
  end
end
