class AddQwen3EmbeddingToTopics < ActiveRecord::Migration[8.1]
  # Add a 1024-dim Qwen3 embedding for each topic name so we can do
  # semantic topic-name lookup at query time instead of literal substring
  # match. Without this, a query like "hopeless" can't match the `hope`
  # topic, and "faithfulness" can't match `faith` — natural English
  # morphology that the literal matcher missed.
  #
  # Encoded via `rake topics:encode_names` which iterates all rows and
  # writes the vector. Document-side encoding (no Qwen3 query prefix)
  # so it lines up with how `EmbeddingEncoder.encode(text, prompt: :document)`
  # produces vectors at search time on the topic-lookup side.

  def up
    execute "ALTER TABLE topics ADD COLUMN name_embedding_qwen3 vector(1024)"

    execute <<~SQL
      CREATE INDEX idx_topics_name_embedding_qwen3_hnsw
        ON topics
        USING hnsw (name_embedding_qwen3 vector_cosine_ops)
        WHERE name_embedding_qwen3 IS NOT NULL
    SQL
  end

  def down
    execute "DROP INDEX IF EXISTS idx_topics_name_embedding_qwen3_hnsw"
    execute "ALTER TABLE topics DROP COLUMN IF EXISTS name_embedding_qwen3"
  end
end
