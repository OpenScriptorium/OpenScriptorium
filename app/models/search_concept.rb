class SearchConcept < ApplicationRecord
  # Curated concept for search retrieval. Links natural-language phrases
  # ("the cross", "burning bush") to signature verses so the search
  # pipeline can surface the right passage even when the query keyword
  # is absent from the verse text. See SEARCH_PLAN.md Phase 2.
  has_paper_trail

  KINDS = %w[event topic title place parable character role attribute].freeze

  has_many :search_concept_verses, dependent: :destroy
  has_many :canonical_refs, through: :search_concept_verses
  belongs_to :import_run, optional: true

  validates :name, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }
  validates :aliases, presence: true

  scope :of_kind, ->(k) { where(kind: k) }

  # Return concepts whose aliases match any of the given query phrases
  # (case-insensitive substring). Uses the GIN index via ILIKE ANY.
  def self.matching_phrase(phrase)
    return none if phrase.blank?
    where("EXISTS (SELECT 1 FROM unnest(aliases) a WHERE a ILIKE ?)", "%#{sanitize_sql_like(phrase)}%")
  end
end
