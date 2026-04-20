class PassageAlias < ApplicationRecord
  has_many :passage_alias_names, dependent: :destroy

  validates :ref, presence: true

  belongs_to :import_run, optional: true
end
