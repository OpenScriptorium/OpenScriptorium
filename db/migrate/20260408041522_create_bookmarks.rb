class CreateBookmarks < ActiveRecord::Migration[8.1]
  def change
    create_table :bookmarks do |t|
      t.references :user,           null: false, foreign_key: true
      t.references :canonical_work, null: false, foreign_key: true
      t.references :canonical_ref,  null: false, foreign_key: true
      t.string     :label
      t.timestamps
    end

    add_index :bookmarks, [:user_id, :canonical_ref_id], unique: true
  end
end
