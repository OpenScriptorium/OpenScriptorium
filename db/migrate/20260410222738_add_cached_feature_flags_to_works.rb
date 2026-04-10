class AddCachedFeatureFlagsToWorks < ActiveRecord::Migration[8.1]
  def change
    add_column :works, :cached_feature_flags, :string, array: true, default: []
  end
end
