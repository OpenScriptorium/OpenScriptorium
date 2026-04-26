class AddQwen3EmbeddingToPericopes < ActiveRecord::Migration[8.1]
  # Add a 1024-dim Qwen3-Embedding column alongside the existing 768-dim LaBSE
  # `name_embedding`. Both columns coexist during the model migration so a
  # `git revert` of the search code can fall back to LaBSE without re-encoding.
  # A follow-up cleanup migration will drop the LaBSE column once Qwen3 is
  # confirmed stable in production.
  def up
    execute "ALTER TABLE pericopes ADD COLUMN name_embedding_qwen3 vector(1024)"

    # HNSW index, partial on non-null values (matches the LaBSE index pattern).
    execute <<~SQL
      CREATE INDEX idx_pericopes_name_embedding_qwen3_hnsw
      ON pericopes
      USING hnsw (name_embedding_qwen3 vector_cosine_ops)
      WHERE name_embedding_qwen3 IS NOT NULL
    SQL
  end

  def down
    execute "DROP INDEX IF EXISTS idx_pericopes_name_embedding_qwen3_hnsw"
    execute "ALTER TABLE pericopes DROP COLUMN IF EXISTS name_embedding_qwen3"
  end
end
