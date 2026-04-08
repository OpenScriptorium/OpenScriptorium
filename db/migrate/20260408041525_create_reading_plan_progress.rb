class CreateReadingPlanProgress < ActiveRecord::Migration[8.1]
  def change
    create_table :reading_plan_progress do |t|
      t.references :user,                null: false, foreign_key: true
      t.references :reading_plan,        null: false, foreign_key: true
      t.references :reading_plan_entry,  null: false, foreign_key: true
      t.datetime   :completed_at,        null: false
      t.timestamps
    end

    add_index :reading_plan_progress,
              [:user_id, :reading_plan_entry_id], unique: true,
              name: "idx_rp_progress_unique"
  end
end
