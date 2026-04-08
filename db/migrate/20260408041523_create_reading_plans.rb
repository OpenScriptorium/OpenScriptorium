class CreateReadingPlans < ActiveRecord::Migration[8.1]
  def change
    create_table :reading_plans do |t|
      t.string     :slug,             null: false
      t.string     :title,            null: false
      t.text       :description
      t.references :created_by_user,  null: false, foreign_key: { to_table: :users }
      t.boolean    :is_public,        null: false, default: false
      t.integer    :length_days
      t.timestamps
    end

    add_index :reading_plans, :slug, unique: true
    add_index :reading_plans, :is_public
  end
end
