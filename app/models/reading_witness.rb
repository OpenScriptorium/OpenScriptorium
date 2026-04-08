class ReadingWitness < ApplicationRecord
  belongs_to :reading
  belongs_to :manuscript

  CERTAINTIES = %w[certain probable possible doubtful].freeze

  validates :certainty, inclusion: { in: CERTAINTIES, allow_nil: true }
  validates :manuscript_id, uniqueness: { scope: :reading_id }
end
