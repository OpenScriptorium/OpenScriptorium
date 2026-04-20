class AddRoleToWords < ActiveRecord::Migration[8.1]
  def change
    add_column :words, :role, :string
  end
end
