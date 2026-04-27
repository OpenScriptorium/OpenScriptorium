class DropLabseEmbeddingColumns < ActiveRecord::Migration[8.1]
  # Drops the legacy LaBSE-era embedding columns and their HNSW indexes:
  #   - work_units.body_embedding   vector(768)
  #   - pericopes.name_embedding    vector(768)
  #
  # Both were superseded by the Qwen3 columns (work_unit_embeddings_qwen3_06b
  # side table, pericopes.name_embedding_qwen3 inline) when the bi-encoder
  # was swapped on 2026-04-25. They've sat unused since.
  #
  # On prod work_units carries a 768-dim float vector per row × ~672k rows ≈
  # 1.9 GB inline, plus the HNSW index. Dropping reclaims ~5 GB after
  # VACUUM FULL (run separately — too long to hold the table-level
  # AccessExclusiveLock that VACUUM FULL takes inside a deploy).

  def up
    if index_exists?(:work_units, :body_embedding, name: "idx_work_units_body_embedding_hnsw")
      remove_index :work_units, name: "idx_work_units_body_embedding_hnsw"
    end
    if column_exists?(:work_units, :body_embedding)
      remove_column :work_units, :body_embedding
    end

    if index_exists?(:pericopes, :name_embedding, name: "idx_pericopes_name_embedding_hnsw")
      remove_index :pericopes, name: "idx_pericopes_name_embedding_hnsw"
    end
    if column_exists?(:pericopes, :name_embedding)
      remove_column :pericopes, :name_embedding
    end
  end

  def down
    add_column :work_units, :body_embedding, :vector, limit: 768
    execute(<<~SQL)
      CREATE INDEX idx_work_units_body_embedding_hnsw
        ON work_units USING hnsw (body_embedding vector_cosine_ops)
        WHERE body_embedding IS NOT NULL
    SQL

    add_column :pericopes, :name_embedding, :vector, limit: 768
    execute(<<~SQL)
      CREATE INDEX idx_pericopes_name_embedding_hnsw
        ON pericopes USING hnsw (name_embedding vector_cosine_ops)
        WHERE name_embedding IS NOT NULL
    SQL
    say "Columns recreated empty. Re-run the LaBSE encode pipeline to repopulate."
  end
end
