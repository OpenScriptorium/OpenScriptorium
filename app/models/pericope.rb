class Pericope < ApplicationRecord
  # Named passage groupings — pericopes, parashot, lectionary readings,
  # editorial section headings — at the canonical layer (not per-work),
  # so the same name applies to every translation of the same passage.
  # source_dataset lets us hold multiple pericope schemes simultaneously.
  has_paper_trail

  belongs_to :canonical_work
  belongs_to :import_run, optional: true

  PERICOPE_TYPES = %w[
    pericope
    parashah
    haftarah
    lectionary
    heading
    section
  ].freeze

  validates :name, presence: true
  validates :source_dataset, presence: true
  validates :pericope_type, inclusion: { in: PERICOPE_TYPES, allow_nil: true }

  scope :for_dataset, ->(name) { where(source_dataset: name) }
  scope :ordered,     -> { order(:sequence_number) }

  # Find pericopes covering a particular canonical_ref ord using GIST.
  scope :covering_ord, ->(canonical_work_id, ord) {
    where(canonical_work_id: canonical_work_id)
      .where("canonical_range && int4range(?, ?)", ord, ord + 1)
  }
end
