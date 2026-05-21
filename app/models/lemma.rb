class Lemma < ApplicationRecord
  has_paper_trail

  has_many :words, dependent: :nullify
  belongs_to :lexicon_entry, class_name: "WorkUnit", optional: true
  belongs_to :import_run, optional: true

  # canonical_lemma_id was a self-FK that bridged inflected-form rows
  # ("αιτουντι") to their dictionary form ("αἰτέω"). Since the
  # consolidation pass (rake lemmas:consolidate_inflected) every Word
  # binds directly to its dictionary lemma — no bridges remain. The
  # column and association are kept for forward-compat in case a future
  # use case (variant spelling, transliteration alias) wants them.
  belongs_to :canonical_lemma, class_name: "Lemma", optional: true
  has_many :inflected_forms,
    class_name: "Lemma", foreign_key: :canonical_lemma_id, dependent: :nullify

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
  # Headword + language is NOT unique — Hebrew homonyms like נֵר
  # ("lamp" H5216 vs "Ner" H5369) and Greek homonyms (ὁ ἡ τό
  # vs proper-name doubles) genuinely share spelling but represent
  # distinct dictionary entries. Disambiguation happens at the Word
  # level via strongs_number. See migration
  # 20260520020000_drop_lemma_unique_index_for_homonyms.
  validates :lemma, presence: true
  validates :normalized, presence: true
  validates :attested_period, inclusion: { in: ATTESTED_PERIODS, allow_nil: true }

  scope :for_language, ->(lang) { where(language: lang) }
  scope :by_normalized, ->(query) { where(normalized: query) }

  private

  def nfc_normalize_lemma
    self.lemma = lemma.unicode_normalize(:nfc) if lemma.is_a?(String)
  end
end
