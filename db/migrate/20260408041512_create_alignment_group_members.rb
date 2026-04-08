class CreateAlignmentGroupMembers < ActiveRecord::Migration[8.1]
  # Each row links a word into an alignment group as either a "source"
  # or a "target". A group can have any combination of source and target
  # members, including 0 of either (null alignment).
  def change
    create_table :alignment_group_members do |t|
      t.references :alignment_group, null: false, foreign_key: true
      t.references :word,            null: false, foreign_key: true
      t.string     :role,            null: false  # source | target
      t.integer    :position                       # order within group
      t.timestamps
    end

    add_index :alignment_group_members, :word_id, name: "idx_align_members_word"
    add_index :alignment_group_members,
              [:alignment_group_id, :role, :position],
              name: "idx_align_members_grouping"
  end
end
