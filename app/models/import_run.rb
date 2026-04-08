class ImportRun < ApplicationRecord
  # Per-import-run provenance. Every importer creates one of these and
  # stamps every row it creates or modifies with its id. Combined with
  # PaperTrail (which captures field-level changes) this gives us full
  # provenance for academic reproducibility.
  has_many :works,                   dependent: :nullify
  has_many :work_units,              dependent: :nullify
  has_many :canonical_refs,          dependent: :nullify
  has_many :words,                   dependent: :nullify
  has_many :lemmas,                  dependent: :nullify
  has_many :alignment_groups,        dependent: :nullify
  has_many :alignment_group_members, dependent: :nullify
  has_many :manuscripts,             dependent: :nullify
  has_many :variant_units,           dependent: :nullify
  has_many :readings,                dependent: :nullify
  has_many :reading_witnesses,       dependent: :nullify
  has_many :cross_references,        dependent: :nullify
  has_many :work_unit_notes,         dependent: :nullify
  has_many :pericopes,               dependent: :nullify

  STATUSES = %w[running completed failed aborted].freeze

  validates :importer_class, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :started_at, presence: true

  scope :recent, -> { order(started_at: :desc) }
  scope :for_importer, ->(klass) { where(importer_class: klass.to_s) }

  def duration
    return nil unless finished_at && started_at
    finished_at - started_at
  end

  def complete!(stats: {})
    update!(
      status: "completed",
      finished_at: Time.current,
      stats: self.stats.merge(stats)
    )
  end

  def fail!(error)
    update!(
      status: "failed",
      finished_at: Time.current,
      error_message: error.message,
      error_backtrace: Array(error.backtrace).first(50).join("\n")
    )
  end
end
