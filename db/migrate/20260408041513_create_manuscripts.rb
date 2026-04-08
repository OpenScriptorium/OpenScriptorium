class CreateManuscripts < ActiveRecord::Migration[8.1]
  # Manuscript witnesses for the critical apparatus tables.
  # Examples: Codex Vaticanus (B), 𝔓46, Codex Sinaiticus (01).
  def change
    create_table :manuscripts do |t|
      t.string  :siglum,            null: false  # short identifier ("B", "𝔓46", "01")
      t.string  :name
      t.string  :date_text                       # human-readable date ("4th century")
      t.integer :date_year_estimate              # numeric estimate for sorting
      t.string  :family                          # alexandrian, byzantine, western, caesarean
      t.string  :language
      t.string  :location
      t.text    :description
      t.string  :image_url
      t.timestamps
    end

    add_index :manuscripts, :siglum, unique: true
    add_index :manuscripts, :family
  end
end
