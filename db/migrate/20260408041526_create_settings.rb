class CreateSettings < ActiveRecord::Migration[8.1]
  # Singleton site-wide settings. Using a key/value model rather than a
  # one-row table makes it easier to add new keys without migrations.
  def change
    create_table :settings do |t|
      t.string :key,   null: false
      t.text   :value
      t.timestamps
    end

    add_index :settings, :key, unique: true
  end
end
