class License < ApplicationRecord
  has_many :works, dependent: :restrict_with_error

  validates :name, presence: true, uniqueness: true
  validates :spdx_id, uniqueness: true, allow_nil: true

  scope :alphabetical, -> { order(:name) }
end
