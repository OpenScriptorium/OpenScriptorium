class CorpusStats
  TTL = 1.day

  COUNTABLE = {
    works:                  "Work",
    canonical_works:        "CanonicalWork",
    canonical_refs:         "CanonicalRef",
    work_units:             "WorkUnit",
    words:                  "Word",
    lemmas:                 "Lemma",
    cross_references:       "CrossReference",
    alignment_groups:       "AlignmentGroup",
    pericopes:              "Pericope",
    versification_mappings: "VersificationMapping",
    syntax_nodes:           "SyntaxNode",
    participant_references: "ParticipantReference"
  }.freeze

  def self.count(key)
    Rails.cache.fetch("corpus_stats/v1/#{key}", expires_in: TTL) do
      klass = COUNTABLE.fetch(key.to_sym).constantize
      klass.count
    end
  end

  def self.totals
    COUNTABLE.keys.index_with { |k| count(k) }
  end

  def self.expire!
    COUNTABLE.each_key { |k| Rails.cache.delete("corpus_stats/v1/#{k}") }
  end

  def self.xref_datasets
    Rails.cache.fetch("corpus_stats/v1/xref_datasets", expires_in: TTL) do
      CrossReference.distinct.pluck(:source_dataset).compact.sort
    end
  end
end
