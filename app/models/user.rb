class User < ApplicationRecord
  has_secure_password
  has_paper_trail ignore: [:password_digest, :updated_at]

  has_many :sessions, dependent: :destroy

  belongs_to :invited_by_user, class_name: "User", optional: true
  has_many :invitations,
           class_name: "Invitation",
           foreign_key: :created_by_user_id,
           dependent: :destroy
  has_many :annotations, dependent: :destroy
  has_many :personal_notes, dependent: :destroy
  has_many :bookmarks, dependent: :destroy
  has_many :reading_plans,
           class_name: "ReadingPlan",
           foreign_key: :created_by_user_id,
           dependent: :destroy
  has_many :reading_plan_progress,
           class_name: "ReadingPlanProgress",
           dependent: :destroy
  has_many :submitted_cross_references,
           class_name: "CrossReference",
           foreign_key: :created_by_user_id,
           dependent: :nullify

  ROLES = %w[visitor contributor moderator admin].freeze

  validates :role, inclusion: { in: ROLES }

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  scope :admins,       -> { where(role: "admin") }
  scope :contributors, -> { where(role: %w[contributor moderator admin]) }

  def admin?
    role == "admin"
  end

  def moderator?
    %w[moderator admin].include?(role)
  end

  def contributor?
    %w[contributor moderator admin].include?(role)
  end
end
