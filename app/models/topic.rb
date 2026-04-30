class Topic < ApplicationRecord
  has_paper_trail
  belongs_to :license, optional: true
  belongs_to :import_run, optional: true
  has_many :topic_verses, dependent: :destroy
  has_many :canonical_refs, through: :topic_verses

  validates :source, :source_topic_id, :name, presence: true
  validates :source_topic_id, uniqueness: { scope: :source }

  scope :by_source, ->(s) { where(source: s) }
  scope :matching_name, ->(n) { where(name: n.to_s.downcase.strip) }
end
