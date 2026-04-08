class CanonicalRef < ApplicationRecord
  # The smallest abstract addressable unit within a canonical_work.
  # `ord` is sequential within the canonical_work and drives int4range
  # queries on cross_references.
  belongs_to :canonical_work
  has_many   :work_units, dependent: :nullify
  has_many   :variant_units, dependent: :destroy
  has_many   :alignment_groups, dependent: :destroy
  has_many   :bookmarks, dependent: :destroy

  validates :ord, presence: true,
                  uniqueness: { scope: :canonical_work_id }
  validates :display_label, presence: true
  validates :hierarchy, presence: true

  scope :in_order, -> { order(:ord) }
  scope :for_chapter, ->(chapter) { where("hierarchy[1] = ?", chapter) }
  scope :for_verse,   ->(chapter, verse) { where("hierarchy[1] = ? AND hierarchy[2] = ?", chapter, verse) }
end
