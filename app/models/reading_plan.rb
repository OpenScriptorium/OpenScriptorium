class ReadingPlan < ApplicationRecord
  belongs_to :created_by_user, class_name: "User"

  has_many :reading_plan_entries, dependent: :destroy
  has_many :reading_plan_progress, dependent: :destroy

  validates :slug, presence: true, uniqueness: true,
                   format: { with: /\A[a-z0-9-]+\z/ }
  validates :title, presence: true

  scope :public_plans, -> { where(is_public: true) }

  def to_param
    slug
  end
end
