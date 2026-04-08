class Invitation < ApplicationRecord
  belongs_to :created_by_user, class_name: "User"
  belongs_to :used_by_user,    class_name: "User", optional: true

  validates :code, presence: true, uniqueness: true

  scope :unused,  -> { where(used_at: nil) }
  scope :unexpired, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }

  def used?
    used_at.present?
  end

  def expired?
    expires_at.present? && expires_at < Time.current
  end

  def redeemable?
    !used? && !expired?
  end
end
