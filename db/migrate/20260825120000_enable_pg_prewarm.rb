class EnablePgPrewarm < ActiveRecord::Migration[8.1]
  # Enable pg_prewarm so we can pull the HNSW indexes and the embeddings
  # table into shared_buffers at boot. Cold-cache HNSW probes are the
  # dominant tail-latency source in the p95/p99 semantic search path;
  # prewarming eliminates the disk-read spike on the first query after
  # a Postgres restart.
  def change
    enable_extension "pg_prewarm"
  end
end
