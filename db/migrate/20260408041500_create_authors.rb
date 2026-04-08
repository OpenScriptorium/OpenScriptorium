class CreateAuthors < ActiveRecord::Migration[8.1]
  def change
    create_table :authors do |t|
      t.string  :slug,             null: false
      t.string  :name,             null: false
      t.string  :sort_name
      t.string  :latin_name
      t.string  :native_name
      t.integer :birth_year
      t.integer :death_year
      t.string  :era
      t.string  :tradition
      t.text    :bio
      t.string  :wikipedia_url
      t.timestamps
    end

    add_index :authors, :slug, unique: true
    add_index :authors, :sort_name
    add_index :authors, :tradition
  end
end
