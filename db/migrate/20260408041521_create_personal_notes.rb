class CreatePersonalNotes < ActiveRecord::Migration[8.1]
  # Private notes a user attaches to a passage. Same shape as annotations
  # but never enters the moderation queue and is only visible to the user.
  def change
    create_table :personal_notes do |t|
      t.references :user,           null: false, foreign_key: true
      t.references :canonical_work, null: false, foreign_key: true
      t.text       :body_markdown,  null: false
      t.text       :body_html
      t.timestamps
    end

    execute <<~SQL
      ALTER TABLE personal_notes ADD COLUMN canonical_range int4range NOT NULL;
      CREATE INDEX idx_personal_notes_range
        ON personal_notes USING gist (user_id, canonical_work_id, canonical_range);
    SQL
  end
end
