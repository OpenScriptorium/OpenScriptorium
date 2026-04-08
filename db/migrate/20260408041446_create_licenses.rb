class CreateLicenses < ActiveRecord::Migration[8.1]
  def change
    create_table :licenses do |t|
      t.string  :name,                  null: false
      t.string  :spdx_id
      t.string  :url
      t.boolean :attribution_required,  null: false, default: false
      t.string  :attribution_template
      t.text    :description
      t.timestamps
    end

    add_index :licenses, :spdx_id, unique: true
    add_index :licenses, :name,    unique: true
  end
end
