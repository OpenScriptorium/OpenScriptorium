class ParticipantReference < ApplicationRecord
  belongs_to :word
  belongs_to :referent_word, class_name: "Word", optional: true
  belongs_to :work_unit
  belongs_to :import_run, optional: true

  validates :ref_type, presence: true, inclusion: {
    in: %w[participant subject frame_a0 frame_a1 frame_a2]
  }

  scope :participants, -> { where(ref_type: "participant") }
  scope :subjects, -> { where(ref_type: "subject") }
  scope :agents, -> { where(ref_type: "frame_a0") }
  scope :patients, -> { where(ref_type: "frame_a1") }
end
