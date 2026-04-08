class ReadingPlanProgress < ApplicationRecord
  self.table_name = "reading_plan_progress"

  belongs_to :user
  belongs_to :reading_plan
  belongs_to :reading_plan_entry

  validates :reading_plan_entry_id, uniqueness: { scope: :user_id }
end
