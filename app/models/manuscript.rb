class Manuscript < ApplicationRecord
  has_many :reading_witnesses, dependent: :destroy
  has_many :readings, through: :reading_witnesses

  FAMILIES = %w[alexandrian byzantine western caesarean other].freeze

  validates :siglum, presence: true, uniqueness: true
  validates :family, inclusion: { in: FAMILIES, allow_nil: true }

  scope :ordered, -> { order(:date_year_estimate, :siglum) }
end
