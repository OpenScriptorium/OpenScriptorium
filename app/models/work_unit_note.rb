class WorkUnitNote < ApplicationRecord
  # First-class translator/editor notes attached to a work_unit.
  # If we put these into work_units.markup we lose query power; this
  # table lets us answer "all text-critical notes in BSB" with one query.
  has_paper_trail

  belongs_to :work_unit
  belongs_to :import_run, optional: true

  NOTE_TYPES = %w[
    textual
    translation
    cross_reference
    explanation
    editorial
  ].freeze

  validates :body, presence: true
  validates :note_type, inclusion: { in: NOTE_TYPES }

  scope :textual,         -> { where(note_type: "textual") }
  scope :translation_notes, -> { where(note_type: "translation") }
  scope :cross_reference_notes, -> { where(note_type: "cross_reference") }
  scope :explanatory,     -> { where(note_type: "explanation") }
  scope :editorial,       -> { where(note_type: "editorial") }
  scope :in_order,        -> { order(:position_in_unit) }
end
