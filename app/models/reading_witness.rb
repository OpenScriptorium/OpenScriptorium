class ReadingWitness < ApplicationRecord
  belongs_to :reading
  belongs_to :manuscript
  belongs_to :import_run, optional: true

  CERTAINTIES = %w[certain probable possible doubtful].freeze

  # Corrector / hand layer vocabulary. Stable but extensible — validated
  # against this constant in the model rather than a Postgres enum so we
  # can add values without DDL when an unfamiliar critical edition shows
  # up. Examples in real apparatus:
  #
  #   *    original first hand
  #   1    first corrector hand
  #   2    second corrector hand
  #   3    third corrector hand
  #   c    corrected (no specific hand)
  #   vid  videtur ("apparently") — uncertain reading
  #   mg   in the margin
  #   txt  in the main text
  #   suppl supplied by a later hand
  CORRECTION_LAYERS = %w[* 1 2 3 c vid mg txt suppl].freeze

  validates :certainty, inclusion: { in: CERTAINTIES, allow_nil: true }
  validates :manuscript_id, uniqueness: { scope: :reading_id }
end
