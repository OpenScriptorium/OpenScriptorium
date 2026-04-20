class AddDomainCodesToWords < ActiveRecord::Migration[8.1]
  def change
    add_column :words, :sdbh, :string
    add_column :words, :lexdomain, :string
    add_column :words, :coredomain, :string
  end
end
