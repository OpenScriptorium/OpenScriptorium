class Reading < ApplicationRecord
  belongs_to :variant_unit
  belongs_to :import_run, optional: true
  has_many :reading_witnesses, dependent: :destroy
  has_many :manuscripts, through: :reading_witnesses

  validates :text, presence: true
end
