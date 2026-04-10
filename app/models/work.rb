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

  # ---------------------------------------------------------------
  # Feature flags
  # ---------------------------------------------------------------
  # Per-work features displayed in the works index legend (NTS / LEM /
  # STR / PRS / ALN / PRC). Each predicate is one indexed query against
  # the table that holds the feature data; the works index page calls
  # `feature_flags` once per work and renders the resulting array.
  #
  # XRF (cross-references) and APP (apparatus) are deliberately not
  # per-work features — cross_references are keyed on canonical_refs
  # and apply to every work that aligns to those refs, so the per-work
  # flag would degenerate to "yes for everything". They live on the
  # verse view's apparatus panel instead.

  FEATURE_DEFINITIONS = [
    ["NTS", :has_notes?,      "Notes",      "translator/editor footnotes or marginalia"],
    ["LEM", :has_lemmas?,     "Lemmas",     "dictionary form per word"],
    ["STR", :has_strongs?,    "Strong's",   "Strong's concordance numbers per word"],
    ["PRS", :has_parsing?,    "Parsing",    "morphological analysis per word"],
    ["ALN", :has_alignment?,  "Alignment",  "Macula-style word-level alignment to source-language texts"],
    ["PRC", :has_pericopes?,  "Pericopes",  "named passage groupings (parashot, BHS pericopes, lectionaries…)"],
    ["QUO", :has_red_letter?, "Quotations", "words of Christ marked for red-letter display"],
    ["APP", :has_apparatus?,  "Apparatus",  "critical apparatus with manuscript witnesses and variant readings"]
  ].freeze

  def feature_flags
    FEATURE_DEFINITIONS.filter_map { |abbr, predicate, _label, _desc| abbr if send(predicate) }
  end

  def has_notes?
    WorkUnitNote.where(work_unit_id: work_units.select(:id)).exists?
  end

  def has_lemmas?
    Word.where(work_id: id).where.not(lemma_id: nil).exists?
  end

  def has_strongs?
    Word.where(work_id: id).where.not(strongs_number: [nil, ""]).exists?
  end

  def has_parsing?
    Word.where(work_id: id).where.not(morph_code: [nil, ""]).exists?
  end

  def has_alignment?
    AlignmentGroup.where(source_work_id: id).or(AlignmentGroup.where(target_work_id: id)).exists?
  end

  def has_pericopes?
    return false if pericope_traditions.blank?
    canonical_work_ids = work_units.joins(:canonical_ref).distinct.pluck("canonical_refs.canonical_work_id")
    return false if canonical_work_ids.empty?
    Pericope.where(canonical_work_id: canonical_work_ids, tradition: pericope_traditions).exists?
  end

  def has_red_letter?
    work_units.where("markup ? :key", key: "red_letter_positions").exists?
  end

  def has_apparatus?
    # APP only shows for works that specifically have apparatus data
    # imported for them. We check if any VariantUnit was created by
    # an import_run whose importer class references this work (via
    # the work's canonical_refs). For now, only Nestle 1904 and CNTR
    # SR have apparatus data — other Greek NTs share the same
    # canonical_refs but didn't bring their own apparatus.
    return false unless work_type == "scripture_original"
    return false unless %w[nestle1904 cntr-sr].include?(slug)
    canonical_work_ids = work_units.joins(:canonical_ref).distinct.pluck("canonical_refs.canonical_work_id")
    return false if canonical_work_ids.empty?
    VariantUnit.where(canonical_ref_id: CanonicalRef.where(canonical_work_id: canonical_work_ids).select(:id)).exists?
  end
end
