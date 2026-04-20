class AddAlternateTitlesToCanonicalWorks < ActiveRecord::Migration[8.1]
  def change
    add_column :canonical_works, :alternate_titles, :jsonb
  end
end
