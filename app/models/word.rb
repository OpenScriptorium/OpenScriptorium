class Word < ApplicationRecord
  belongs_to :work
  belongs_to :work_unit
  belongs_to :lemma, optional: true
  belongs_to :import_run, optional: true
  belongs_to :syntax_node, optional: true

  has_many :alignment_group_members, dependent: :destroy
  has_many :alignment_groups, through: :alignment_group_members
  has_many :participant_references, dependent: :destroy
  has_many :referencing_words, class_name: "ParticipantReference", foreign_key: :referent_word_id

  validates :surface, presence: true
  validates :position, presence: true,
                       uniqueness: { scope: :work_unit_id }

  scope :in_order, -> { order(:position) }
end
