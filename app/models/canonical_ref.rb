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

  # Returns the canonical_ref(s) in `target_scheme` (a VersificationScheme
  # or its code string) equivalent to this ref.
  #
  # The lookup uses TVTMS-imported `versification_mappings` rows. A mapping
  # may apply in either direction — this ref might be the `from` side or
  # the `to` side of the row, so we check both.
  #
  # Behavior by case:
  #
  #   * Same scheme as self.canonical_work        → returns [self]
  #   * `mapping_type: missing`                   → returns []
  #     (the verse does not exist in the target scheme)
  #   * `split` (1→N)                             → returns N refs
  #   * `merge` (N→1)                             → returns 1 ref
  #     (the same target ref will be returned for each of the N source refs)
  #   * No matching mapping row exists            → assumes identity:
  #     looks for a canonical_ref in the target scheme with the same
  #     hierarchy under a canonical_work sharing this ref's book_key.
  #     This is correct for the overwhelming majority of verses where
  #     schemes agree implicitly.
  #
  # Returns Array<CanonicalRef> (possibly empty for `missing`).
  def equivalent_in(target_scheme)
    target_scheme = VersificationScheme.find_by!(code: target_scheme) if target_scheme.is_a?(String)
    return [self] if canonical_work.versification_scheme_id == target_scheme.id

    forward = VersificationMapping
                .where(from_canonical_ref_id: id, to_scheme_id: target_scheme.id)
                .includes(:to_canonical_ref)
    reverse = VersificationMapping
                .where(to_canonical_ref_id: id, from_scheme_id: target_scheme.id)
                .includes(:from_canonical_ref)

    refs = []
    has_explicit = false

    forward.each do |m|
      has_explicit = true
      next if m.mapping_type == "missing"
      refs << m.to_canonical_ref
    end

    reverse.each do |m|
      has_explicit = true
      next if m.mapping_type == "missing"
      refs << m.from_canonical_ref
    end

    return refs.uniq if has_explicit

    # Identity fallback: look for a canonical_work sharing this book_key
    # but tagged with the target scheme. If one exists, that's where the
    # equivalent ref lives (e.g. psalms-lxx for the LXX side of Ps 1:1).
    # If no scheme-specific canonical_work exists, the verse is the same
    # across both schemes — most books are like this — so we return self.
    target_cw = CanonicalWork
                  .where(book_key: canonical_work.book_key,
                         versification_scheme_id: target_scheme.id)
                  .first
    return [self] unless target_cw

    [target_cw.canonical_refs.find_by(hierarchy: hierarchy)].compact
  end

  private

  def compute_sbl_citation
    self.sbl_citation = canonical_work.format_citation(hierarchy)
  end
end
