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
  validates :title, presence: true
  validates :testament, inclusion: { in: TESTAMENTS, allow_nil: true }
  validates :citation_format, inclusion: { in: CITATION_FORMATS, allow_nil: true }

  scope :ordered,         -> { order(:position, :title) }
  scope :for_testament,   ->(t) { where(testament: t) }

  def to_param
    slug
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
