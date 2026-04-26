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

  # Greek polytonic and Hebrew lemmas can be written with precomposed legacy
  # codepoints (U+1F71 GREEK SMALL LETTER ALPHA WITH OXIA) OR modern
  # monotonic ones (U+03AC GREEK SMALL LETTER ALPHA WITH TONOS). They render
  # identically but compare unequal, which previously produced duplicate
  # rows (same word, different bytes, two glosses on screen). NFC-normalize
  # at save time so every import path writes the canonical form.
  before_validation :nfc_normalize_lemma

  validates :language, presence: true
  validates :lemma, presence: true,
                    uniqueness: { scope: :language }
  validates :normalized, presence: true
  validates :attested_period, inclusion: { in: ATTESTED_PERIODS, allow_nil: true }

  scope :for_language, ->(lang) { where(language: lang) }
  scope :by_normalized, ->(query) { where(normalized: query) }

  private

  def nfc_normalize_lemma
    self.lemma = lemma.unicode_normalize(:nfc) if lemma.is_a?(String)
  end
end
