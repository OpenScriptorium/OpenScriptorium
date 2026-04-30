class TopicVerse < ApplicationRecord
  has_paper_trail
  belongs_to :topic
  belongs_to :canonical_ref
  belongs_to :import_run, optional: true

  validates :source_rank, presence: true
end
