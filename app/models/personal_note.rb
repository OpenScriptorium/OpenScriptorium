class PersonalNote < ApplicationRecord
  belongs_to :user
  belongs_to :canonical_work

  validates :body_markdown, presence: true

  scope :for_user_canonical_ord, ->(user_id, canonical_work_id, ord) {
    where(user_id: user_id, canonical_work_id: canonical_work_id)
      .where("canonical_range && int4range(?, ?)", ord, ord + 1)
  }
end
