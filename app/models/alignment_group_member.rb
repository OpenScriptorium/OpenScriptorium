class AlignmentGroupMember < ApplicationRecord
  belongs_to :alignment_group
  belongs_to :word
  belongs_to :import_run, optional: true

  ROLES = %w[source target].freeze

  validates :role, inclusion: { in: ROLES }
end
