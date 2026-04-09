class CanonicalWork < ApplicationRecord
  # The abstract concept of a text — "Genesis", "Gospel of Thomas",
  # "Josephus, Antiquities, Bk 1". Translations and editions of the same
  # underlying text align to the same canonical_work via canonical_refs.
  has_paper_trail

  belongs_to :versification_scheme, optional: true
  belongs_to :parent_canonical_work, class_name: "CanonicalWork", optional: true

  has_many :sub_works,
           class_name: "CanonicalWork",
           foreign_key: :parent_canonical_work_id,
           dependent: :restrict_with_error
  has_many :canonical_refs, dependent: :destroy
  has_many :work_units, through: :canonical_refs
  has_many :pericopes, dependent: :destroy

  has_many :annotations,    dependent: :destroy
  has_many :personal_notes, dependent: :destroy
  has_many :bookmarks,      dependent: :destroy

  has_many :source_cross_references,
           class_name: "CrossReference",
           foreign_key: :source_canonical_work_id,
           dependent: :destroy
  has_many :target_cross_references,
           class_name: "CrossReference",
           foreign_key: :target_canonical_work_id,
           dependent: :destroy

  TESTAMENTS = %w[ot nt deuterocanon pseudepigrapha apostolic_father patristic other].freeze
  CITATION_FORMATS = %w[scripture hierarchical].freeze

  validates :slug, presence: true, uniqueness: true,
                   format: { with: /\A[a-z0-9-]+\z/ }
  validates :book_key, presence: true,
                       format: { with: /\A[a-z0-9-]+\z/ }
  validates :title, presence: true
  validates :testament, inclusion: { in: TESTAMENTS, allow_nil: true }
  validates :citation_format, inclusion: { in: CITATION_FORMATS, allow_nil: true }

  scope :ordered,         -> { order(:position, :title) }
  scope :for_testament,   ->(t) { where(testament: t) }
  scope :for_book_key,    ->(key) { where(book_key: key) }
  # All canonical_works that hold work_units for the given Work id.
  scope :used_by_work,    ->(work_id) {
    joins(canonical_refs: :work_units)
      .where(work_units: { work_id: work_id })
      .distinct
  }

  def to_param
    slug
  end

  # The canonical_work's title with any scheme parenthetical stripped
  # for end-user display. Internal slugs like `psalms-mt` and
  # `psalms-german` carry titles like "Psalms (MT)" / "Psalms (German)"
  # to keep the catalog unambiguous, but the reader is always showing a
  # specific Work — the user has chosen Luther 1912 or JPS 1917 already
  # — so the scheme tag is noise that leaks implementation detail into
  # the breadcrumbs and headings. Use this everywhere a verse view,
  # chapter view, or book view shows the canonical_work to a reader.
  def display_title
    title.sub(/\s*\((?:MT|KJV|LXX|German|Vulgate|Catholic|NRSV|Synodal|Orthodox)\)\s*\z/, "").strip.presence || title
  end

  # Generate an SBL-style citation string from a hierarchy. Used by
  # CanonicalRef#sbl_citation. Honors citation_format:
  #
  #   "scripture":    "Gen 1:1"  /  "Gen 1:1a"  (with subverse)
  #   "hierarchical": "Philo, QG 1.1"  /  "Josephus, Ant. 1.1.1"
  def format_citation(hierarchy)
    abbr = sbl_abbreviation.presence || title
    case citation_format.presence || "scripture"
    when "scripture"
      ch    = hierarchy[0]
      verse = hierarchy[1]
      part  = hierarchy[2]
      base  = "#{abbr} #{ch}:#{verse}"
      part ? "#{base}#{('a'.ord + part - 1).chr}" : base
    when "hierarchical"
      "#{abbr} #{hierarchy.join('.')}"
    end
  end
end
