class AddNameEmbeddingToPericopes < ActiveRecord::Migration[8.1]
  def change
    add_column :pericopes, :name_embedding, :vector, limit: 768
    add_index :pericopes, :name_embedding,
              using: :hnsw,
              opclass: :vector_cosine_ops,
              where: "name_embedding IS NOT NULL",
              name: "idx_pericopes_name_embedding_hnsw"
  end
end
