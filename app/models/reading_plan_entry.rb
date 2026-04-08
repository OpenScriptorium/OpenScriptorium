class ReadingPlanEntry < ApplicationRecord
  belongs_to :reading_plan
  belongs_to :canonical_work

  has_many :reading_plan_progress, dependent: :destroy
end
