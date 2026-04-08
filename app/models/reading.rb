class Reading < ApplicationRecord
  belongs_to :variant_unit
  has_many :reading_witnesses, dependent: :destroy
  has_many :manuscripts, through: :reading_witnesses

  validates :text, presence: true
end
