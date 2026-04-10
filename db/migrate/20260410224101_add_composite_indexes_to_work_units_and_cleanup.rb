class AddCompositeIndexesToWorkUnitsAndCleanup < ActiveRecord::Migration[8.1]
  def change
    # The reader's main query: work_units WHERE work_id AND canonical_ref_id
    add_index :work_units, [:work_id, :canonical_ref_id],
              name: "idx_work_units_work_canonical_ref"

    # Cross-references: compound index for the approved + dataset + source_work
    # filter used in batch preloading
    add_index :cross_references,
              [:source_canonical_work_id, :status, :source_dataset],
              name: "idx_xrefs_source_status_dataset"
    add_index :cross_references,
              [:target_canonical_work_id, :status, :source_dataset],
              name: "idx_xrefs_target_status_dataset"

    # Drop unused indexes (never hit, ~45 MB on disk)
    remove_index :work_units, name: "index_work_units_on_hierarchy_path"
    remove_index :cross_references, name: "index_cross_references_on_status"
    remove_index :cross_references, name: "index_cross_references_on_approved_by_user_id"
    remove_index :cross_references, name: "index_cross_references_on_created_by_user_id"
    remove_index :work_units, name: "index_work_units_on_parent_id"
  end
end
