class CrossReference < ApplicationRecord
  # A cross-reference between any two passages, stored at the canonical
  # layer. source_range and target_range are int4ranges over
  # canonical_refs.ord, indexed with GIST for fast overlap queries.
  has_paper_trail

  belongs_to :source_canonical_work, class_name: "CanonicalWork"
  belongs_to :target_canonical_work, class_name: "CanonicalWork"
  belongs_to :created_by_user,  class_name: "User", optional: true
  belongs_to :approved_by_user, class_name: "User", optional: true

  RELATIONSHIP_TYPES = %w[
    quotes alludes_to parallels comments_on fulfills
    contradicts paraphrases cites_as_authority
  ].freeze

  STATUSES = %w[proposed approved rejected].freeze

  validates :relationship_type, inclusion: { in: RELATIONSHIP_TYPES }
  validates :status, inclusion: { in: STATUSES }

  scope :approved, -> { where(status: "approved") }

  # Find all approved cross-references whose source_range overlaps the
  # given canonical_ref ord. Uses the GIST index.
  scope :for_source_ord, ->(canonical_work_id, ord) {
    where(source_canonical_work_id: canonical_work_id)
      .where("source_range && int4range(?, ?)", ord, ord + 1)
  }

  scope :for_target_ord, ->(canonical_work_id, ord) {
    where(target_canonical_work_id: canonical_work_id)
      .where("target_range && int4range(?, ?)", ord, ord + 1)
  }
end
