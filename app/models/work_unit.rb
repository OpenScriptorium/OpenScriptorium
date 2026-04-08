class WorkUnit < ApplicationRecord
  # The smallest addressable piece of any work — a verse, a Loeb section,
  # a logion, a paragraph. canonical_ref_id aligns this unit to the
  # abstract canonical layer (so all translations of Gen 1:1 share a
  # canonical_ref).
  has_paper_trail

  belongs_to :work
  belongs_to :parent, class_name: "WorkUnit", optional: true
  belongs_to :canonical_ref, optional: true

  has_many :children,
           class_name: "WorkUnit",
           foreign_key: :parent_id,
           dependent: :destroy
  has_many :words, dependent: :destroy

  ALIGNMENT_TYPES = %w[exact approximate ambiguous none].freeze

  validates :ord, presence: true,
                  uniqueness: { scope: :work_id }
  validates :canonical_alignment_type, inclusion: { in: ALIGNMENT_TYPES }

  scope :in_order, -> { order(:ord) }

  # Find by canonical chapter+verse hierarchy. Used by the reader UI.
  scope :for_chapter, ->(chapter) {
    joins(:canonical_ref)
      .where("canonical_refs.hierarchy[1] = ?", chapter)
      .order("canonical_refs.ord")
  }
  scope :for_verse, ->(chapter, verse) {
    joins(:canonical_ref)
      .where("canonical_refs.hierarchy[1] = ? AND canonical_refs.hierarchy[2] = ?",
             chapter, verse)
  }
end
