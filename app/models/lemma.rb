class Lemma < ApplicationRecord
  has_paper_trail

  has_many :words, dependent: :nullify
  belongs_to :lexicon_entry, class_name: "WorkUnit", optional: true
  belongs_to :import_run, optional: true

  ATTESTED_PERIODS = %w[
    biblical_hebrew
    second_temple
    rabbinic
    classical_greek
    koine
    patristic
    medieval
  ].freeze

  validates :language, presence: true
  validates :lemma, presence: true,
                    uniqueness: { scope: :language }
  validates :normalized, presence: true
  validates :attested_period, inclusion: { in: ATTESTED_PERIODS, allow_nil: true }

  scope :for_language, ->(lang) { where(language: lang) }
  scope :by_normalized, ->(query) { where(normalized: query) }
end
