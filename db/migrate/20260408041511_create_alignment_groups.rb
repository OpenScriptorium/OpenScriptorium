class CreateAlignmentGroups < ActiveRecord::Migration[8.1]
  # Macula-compatible word alignment between an original work and a
  # translation. Each group contains some source words and some target
  # words. Supports 1:1, 1:n, n:1, n:n, null source / null target,
  # non-monotonic.
  def change
    create_table :alignment_groups do |t|
      t.references :canonical_ref, null: false, foreign_key: true
      t.references :source_work,   null: false, foreign_key: { to_table: :works }
      t.references :target_work,   null: false, foreign_key: { to_table: :works }
      t.string     :alignment_type, null: false, default: "literal"
        # literal, idiomatic, supplied, null_source, null_target
      t.decimal    :confidence, precision: 4, scale: 3
      t.timestamps
    end

    add_index :alignment_groups,
              [:canonical_ref_id, :source_work_id, :target_work_id],
              name: "idx_align_groups_lookup"
  end
end
