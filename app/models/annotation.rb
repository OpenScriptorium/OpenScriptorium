class Annotation < ApplicationRecord
  has_paper_trail ignore: [:body_html, :updated_at]

  belongs_to :user
  belongs_to :canonical_work
  belongs_to :reviewed_by_user, class_name: "User", optional: true

  STATUSES    = %w[draft submitted approved rejected].freeze
  VISIBILITIES = %w[private public].freeze

  validates :body_markdown, presence: true
  validates :status,        inclusion: { in: STATUSES }
  validates :visibility,    inclusion: { in: VISIBILITIES }

  scope :approved, -> { where(status: "approved") }
  scope :public_visibility, -> { where(visibility: "public") }

  scope :for_canonical_ord, ->(canonical_work_id, ord) {
    where(canonical_work_id: canonical_work_id)
      .where("canonical_range && int4range(?, ?)", ord, ord + 1)
  }
end
