class Manuscript < ApplicationRecord
  has_many :reading_witnesses, dependent: :destroy
  has_many :readings, through: :reading_witnesses
  belongs_to :import_run, optional: true

  FAMILIES  = %w[alexandrian byzantine western caesarean other].freeze
  MATERIALS = %w[vellum parchment papyrus paper ostracon].freeze
  FORMATS   = %w[codex scroll fragment tablet ostracon].freeze

  validates :siglum, presence: true, uniqueness: true
  validates :family,   inclusion: { in: FAMILIES,  allow_nil: true }
  validates :material, inclusion: { in: MATERIALS, allow_nil: true }
  validates :format,   inclusion: { in: FORMATS,   allow_nil: true }

  scope :ordered, -> { order(:date_year_estimate, :siglum) }
  scope :by_gregory_aland, ->(num) { where(gregory_aland_number: num) }
end
