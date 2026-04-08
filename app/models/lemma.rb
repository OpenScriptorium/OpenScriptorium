class Lemma < ApplicationRecord
  has_paper_trail

  has_many :words, dependent: :nullify
  belongs_to :lexicon_entry, class_name: "WorkUnit", optional: true

  validates :language, presence: true
  validates :lemma, presence: true,
                    uniqueness: { scope: :language }
  validates :normalized, presence: true

  scope :for_language, ->(lang) { where(language: lang) }
  scope :by_normalized, ->(query) { where(normalized: query) }
end
