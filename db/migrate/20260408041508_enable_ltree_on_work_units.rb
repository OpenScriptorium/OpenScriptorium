class EnableLtreeOnWorkUnits < ActiveRecord::Migration[8.1]
  # Convert work_units.hierarchy_path from text → ltree, with a GIST
  # index. ltree gives us cheap subtree queries (e.g. "all units under
  # Genesis 1") without recursive CTEs.
  def up
    execute <<~SQL
      ALTER TABLE work_units
        ALTER COLUMN hierarchy_path TYPE ltree
        USING hierarchy_path::ltree;
    SQL
    execute "CREATE INDEX index_work_units_on_hierarchy_path
             ON work_units USING gist (hierarchy_path);"
  end

  def down
    execute "DROP INDEX IF EXISTS index_work_units_on_hierarchy_path;"
    execute "ALTER TABLE work_units ALTER COLUMN hierarchy_path TYPE text;"
  end
end
