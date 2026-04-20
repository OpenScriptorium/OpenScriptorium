class AddXrefCountToCanonicalRefs < ActiveRecord::Migration[8.1]
  def up
    add_column :canonical_refs, :xref_count, :integer, default: 0, null: false

    # Backfill: count cross-references touching each canonical_ref
    execute <<~SQL
      UPDATE canonical_refs cr
      SET xref_count = COALESCE(sub.cnt, 0)
      FROM (
        SELECT cr2.id, COUNT(*) AS cnt
        FROM canonical_refs cr2
        JOIN cross_references xr ON
          (xr.source_canonical_work_id = cr2.canonical_work_id
           AND xr.source_range && int4range(cr2.ord, cr2.ord + 1))
          OR
          (xr.target_canonical_work_id = cr2.canonical_work_id
           AND xr.target_range && int4range(cr2.ord, cr2.ord + 1))
        GROUP BY cr2.id
      ) sub
      WHERE cr.id = sub.id
    SQL
  end

  def down
    remove_column :canonical_refs, :xref_count
  end
end
