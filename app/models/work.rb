class Work < ApplicationRecord
  # Anything with text in the corpus: a scripture translation, an
  # original-language text, a commentary, a treatise, a lexicon. Single
  # polymorphic table with a `work_type` enum.
  has_paper_trail

  belongs_to :license
  belongs_to :default_versification_scheme,
             class_name: "VersificationScheme", optional: true
  belongs_to :import_run, optional: true

  has_many :work_authorships, dependent: :destroy
  has_many :authors, through: :work_authorships
  has_many :work_units, dependent: :destroy
  has_many :words, dependent: :destroy

  has_many :source_alignment_groups,
           class_name: "AlignmentGroup",
           foreign_key: :source_work_id,
           dependent: :destroy
  has_many :target_alignment_groups,
           class_name: "AlignmentGroup",
           foreign_key: :target_work_id,
           dependent: :destroy

  WORK_TYPES = %w[
    scripture_translation
    scripture_original
    commentary
    treatise
    letter
    lexicon
    pseudepigraphon
    apocalypse
    apostolic_father
    other
  ].freeze

  validates :slug, presence: true, uniqueness: true,
                   format: { with: /\A[a-z0-9-]+\z/ }
  validates :title, presence: true
  validates :work_type, inclusion: { in: WORK_TYPES }

  scope :scripture,    -> { where(work_type: %w[scripture_translation scripture_original]) }
  scope :commentaries, -> { where(work_type: "commentary") }
  scope :for_language, ->(lang) { where(language: lang) }

  def to_param
    slug
  end

  # User-facing label for work_type. The internal enum keeps the
  # `scripture_original` name for historical/code reasons; in the UI
  # we present these as "source-language" texts (vs translations) so
  # we don't imply we're displaying autograph manuscripts.
  WORK_TYPE_LABELS = {
    "scripture_translation" => "Scripture translation",
    "scripture_original"    => "Source-language scripture",
    "commentary"            => "Commentary",
    "treatise"              => "Treatise",
    "letter"                => "Letter",
    "lexicon"               => "Lexicon",
    "pseudepigraphon"       => "Pseudepigraphon",
    "apocalypse"            => "Apocalypse",
    "apostolic_father"      => "Apostolic Father",
    "other"                 => "Other"
  }.freeze

  def work_type_label
    WORK_TYPE_LABELS[work_type] || work_type.tr("_", " ").capitalize
  end
end
