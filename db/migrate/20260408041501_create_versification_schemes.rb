class CreateVersificationSchemes < ActiveRecord::Migration[8.1]
  # Crosswire SWORD-style versification schemes (v11n).
  # Examples: KJV, NRSV, NRSVA, MT, LXX, Vulgate, Catholic, German, Synodal,
  # Luther, Leningrad, Orthodox.
  def change
    create_table :versification_schemes do |t|
      t.string :code,         null: false
      t.string :display_name, null: false
      t.text   :description
      t.string :source_url
      t.timestamps
    end

    add_index :versification_schemes, :code, unique: true
  end
end
