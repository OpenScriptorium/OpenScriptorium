class WorkAuthorship < ApplicationRecord
  belongs_to :work
  belongs_to :author

  ROLES = %w[original_author translator editor compiler reviser commentator].freeze

  validates :role, inclusion: { in: ROLES }
  validates :author_id, uniqueness: { scope: [:work_id, :role] }
end
