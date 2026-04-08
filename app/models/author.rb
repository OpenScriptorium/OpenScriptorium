class Author < ApplicationRecord
  has_paper_trail

  has_many :work_authorships, dependent: :destroy
  has_many :works, through: :work_authorships

  validates :slug, presence: true, uniqueness: true,
                   format: { with: /\A[a-z0-9-]+\z/ }
  validates :name, presence: true

  scope :alphabetical, -> { order(:sort_name, :name) }
end
