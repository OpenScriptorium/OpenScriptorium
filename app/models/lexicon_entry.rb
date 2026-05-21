class LexiconEntry < ApplicationRecord
  has_paper_trail
  belongs_to :lemma, optional: true
  belongs_to :license, optional: true
  belongs_to :import_run, optional: true

  validates :source, :headword, presence: true

  scope :for_source, ->(s) { where(source: s) }
  scope :for_lemma, ->(l) { where(lemma_id: l.is_a?(Lemma) ? l.id : l) }
end
