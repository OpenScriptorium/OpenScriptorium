class SearchConceptVerse < ApplicationRecord
  # Link between a curated concept and a signature verse. Role captures
  # what the verse is TO the concept so the strategy can prefer the
  # defining verse over supporting context. Weight is a per-pair
  # multiplier (default 1.0) for curators to tune.
  has_paper_trail

  ROLES = %w[signature climax context quote].freeze

  belongs_to :search_concept
  belongs_to :canonical_ref
  belongs_to :import_run, optional: true

  validates :role, inclusion: { in: ROLES }
  validates :weight, numericality: { greater_than: 0, less_than_or_equal_to: 10 }
  validates :search_concept_id, uniqueness: { scope: :canonical_ref_id }
end
