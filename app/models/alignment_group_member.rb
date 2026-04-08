class AlignmentGroupMember < ApplicationRecord
  belongs_to :alignment_group
  belongs_to :word

  ROLES = %w[source target].freeze

  validates :role, inclusion: { in: ROLES }
end
