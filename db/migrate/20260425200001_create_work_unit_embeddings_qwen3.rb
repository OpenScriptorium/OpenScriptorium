class CreateWorkUnitEmbeddingsQwen3 < ActiveRecord::Migration[8.1]
  # Per-model side table for Qwen3-Embedding-0.6B (1024-dim).
  #
  # Lives alongside (not replacing) work_units.body_embedding (LaBSE 768-dim)
  # during the model migration so a `git revert` of the search code can roll
  # back to LaBSE without re-encoding 706k rows. A follow-up cleanup migration
  # will drop the LaBSE column once Qwen3 is confirmed stable in production.
  #
  # Populated by `rake "embeddings:import_side[qwen3_06b,1024,<tsv_path>]"`
  # using a TSV produced by scripts/train_embeddings/modal_encode.py.
  def up
    return if connection.table_exists?(:work_unit_embeddings_qwen3_06b)

    execute <<~SQL
      CREATE TABLE work_unit_embeddings_qwen3_06b (
        work_unit_id BIGINT PRIMARY KEY,
        embedding vector(1024) NOT NULL
      )
    SQL

    # HNSW index built separately by the bulk-import task — building it after
    # the COPY is orders of magnitude faster than incremental maintenance.
    # The import task creates the index; this migration just creates the table
    # so the deploy schema is complete on a fresh boot. If the index is
    # already present (e.g. on dev), don't touch it.
  end

  def down
    execute "DROP TABLE IF EXISTS work_unit_embeddings_qwen3_06b"
  end
end
