class CanonicalRef < ApplicationRecord
  # The smallest abstract addressable unit within a canonical_work.
  # `ord` is sequential within the canonical_work and drives int4range
  # queries on cross_references.
  #
  # `hierarchy` is a flexible int array. The convention varies by the
  # canonical_work's nature:
  #
  #   Bible verse:           [chapter, verse]
  #   Bible sub-verse:       [chapter, verse, part]
  #                          where part = 1 → 'a', 2 → 'b', etc.
  #   Loeb-style commentary: [book, chapter, section]
  #   Logia (Thomas etc.):   [logion]
  #   Loeb 4-part:           [book, chapter, section, paragraph]
  #
  # The `sbl_citation` cached column is computed from the parent
  # canonical_work's format and abbreviation on save.
  belongs_to :canonical_work
  belongs_to :import_run, optional: true
  has_many   :work_units, dependent: :nullify
  has_many   :variant_units, dependent: :destroy
  has_many   :alignment_groups, dependent: :destroy
  has_many   :bookmarks, dependent: :destroy

  validates :ord, presence: true,
                  uniqueness: { scope: :canonical_work_id }
  validates :display_label, presence: true
  validates :hierarchy, presence: true

  before_save :compute_sbl_citation

  scope :in_order, -> { order(:ord) }
  scope :for_chapter, ->(chapter) { where("hierarchy[1] = ?", chapter) }
  scope :for_verse,   ->(chapter, verse) {
    where("hierarchy[1] = ? AND hierarchy[2] = ?", chapter, verse)
  }

  # Whole verses (no sub-verse part) only.
  scope :whole_verses_only, -> {
    where("array_length(hierarchy, 1) <= 2")
  }

  # Sub-verse parts only.
  scope :subverse_parts_only, -> {
    where("array_length(hierarchy, 1) >= 3")
  }

  # The verse number is the second element (postgres arrays are 1-indexed,
  # but the Ruby array we get back is 0-indexed).
  def chapter
    hierarchy[0]
  end

  def verse
    hierarchy[1]
  end

  # Returns 'a', 'b', 'c'... for sub-verses, or nil for whole verses.
  def subverse_letter
    return nil unless hierarchy.length >= 3 && hierarchy[2]
    ('a'.ord + hierarchy[2] - 1).chr
  end

  private

  def compute_sbl_citation
    self.sbl_citation = canonical_work.format_citation(hierarchy)
  end
end
