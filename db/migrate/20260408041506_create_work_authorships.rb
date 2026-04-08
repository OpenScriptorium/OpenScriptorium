class CreateWorkAuthorships < ActiveRecord::Migration[8.1]
  # Many-to-many between works and authors.
  # Role examples: 'translator', 'editor', 'original_author', 'compiler'.
  def change
    create_table :work_authorships do |t|
      t.references :work,   null: false, foreign_key: true
      t.references :author, null: false, foreign_key: true
      t.string     :role,   null: false
      t.integer    :position
      t.timestamps
    end

    add_index :work_authorships, [:work_id, :author_id, :role], unique: true
  end
end
