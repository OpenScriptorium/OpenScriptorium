class AddTopicCentroidEmbedding < ActiveRecord::Migration[8.1]
  # Centroid embedding per topic — average of the top-K tagged verses'
  # query-time embeddings. Used by TopicRetrieval to surface verses that
  # are semantically near the topic's anchor verses but aren't explicitly
  # tagged in the OpenBible/Sefaria voting data. This bridges the data-gap
  # where popular "go-to" verses (Lam 3:22 for faithfulness, Matt 11:28
  # for overwhelmed) sit in the semantic neighborhood of tagged verses
  # but aren't tagged themselves.
  #
  # Computed via `rake topics:compute_centroids` after the corpus and
  # topic data are both loaded. Stored as a regular vector column; we
  # don't need an HNSW index here because the centroid is the *anchor*
  # we search FROM, not a target we search TO.

  def up
    execute "ALTER TABLE topics ADD COLUMN centroid_embedding_qwen3 vector(1024)"
  end

  def down
    execute "ALTER TABLE topics DROP COLUMN IF EXISTS centroid_embedding_qwen3"
  end
end
