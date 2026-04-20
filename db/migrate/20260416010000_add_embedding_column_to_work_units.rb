class AddEmbeddingColumnToWorkUnits < ActiveRecord::Migration[8.1]
  def up
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    # Nullable 768-dim vector column — null means "not yet encoded"
    execute "ALTER TABLE work_units ADD COLUMN body_embedding vector(768)"

    # HNSW index for approximate nearest-neighbor cosine search.
    # Partial index: only indexes non-null rows, so the index stays
    # small until the corpus is encoded.
    execute <<~SQL
      CREATE INDEX idx_work_units_body_embedding_hnsw
      ON work_units
      USING hnsw (body_embedding vector_cosine_ops)
      WHERE body_embedding IS NOT NULL
    SQL
  end

  def down
    execute "DROP INDEX IF EXISTS idx_work_units_body_embedding_hnsw"
    execute "ALTER TABLE work_units DROP COLUMN IF EXISTS body_embedding"
  end
end
