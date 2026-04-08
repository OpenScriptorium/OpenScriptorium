class AlignmentGroup < ApplicationRecord
  # Macula-compatible word alignment between an original work and a
  # translation. Each group has any number of source words and any
  # number of target words, supporting 1:1, 1:n, n:1, n:n, null source,
  # null target, non-monotonic.
  belongs_to :canonical_ref
  belongs_to :source_work, class_name: "Work"
  belongs_to :target_work, class_name: "Work"

  has_many :alignment_group_members, dependent: :destroy
  has_many :source_members,
           -> { where(role: "source").order(:position) },
           class_name: "AlignmentGroupMember"
  has_many :target_members,
           -> { where(role: "target").order(:position) },
           class_name: "AlignmentGroupMember"
  has_many :source_words, through: :source_members, source: :word
  has_many :target_words, through: :target_members, source: :word

  TYPES = %w[literal idiomatic supplied null_source null_target].freeze

  validates :alignment_type, inclusion: { in: TYPES }
end
