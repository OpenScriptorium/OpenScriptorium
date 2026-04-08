class CreateAnnotations < ActiveRecord::Migration[8.1]
  # Public-facing user commentary on a passage. Body is Markdown
  # (CommonMark via commonmarker), rendered to body_html for fast display.
  # Status enum drives the moderation queue.
  def change
    create_table :annotations do |t|
      t.references :user,           null: false, foreign_key: true
      t.references :canonical_work, null: false, foreign_key: true
      t.text       :body_markdown,  null: false
      t.text       :body_html
      t.string     :status, null: false, default: "draft"
        # draft, submitted, approved, rejected
      t.references :reviewed_by_user, foreign_key: { to_table: :users }
      t.datetime   :reviewed_at
      t.text       :review_notes
      t.string     :visibility, null: false, default: "private"
        # private, public
      t.timestamps
    end

    execute <<~SQL
      ALTER TABLE annotations ADD COLUMN canonical_range int4range NOT NULL;
      CREATE INDEX idx_annotations_range
        ON annotations USING gist (canonical_work_id, canonical_range);
    SQL

    add_index :annotations, :status
    add_index :annotations, [:user_id, :status]
  end
end
