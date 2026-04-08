class Bookmark < ApplicationRecord
  belongs_to :user
  belongs_to :canonical_work
  belongs_to :canonical_ref

  validates :canonical_ref_id, uniqueness: { scope: :user_id }
end
