-- Create a per-model embedding side table for the model race.
-- Usage:
--   psql -v slug=qwen3_06b -v dim=1024 \
--     -f scripts/eval/create_embedding_table.sql
--
-- Creates:
--   work_unit_embeddings_<slug> (work_unit_id PK, embedding vector(<dim>))
--   idx_wue_<slug>_hnsw     HNSW (cosine) on embedding
--
-- Tables are dropped at start so re-running is idempotent. The HNSW index
-- is NOT created here — it's added after bulk-loading by the import script
-- (orders of magnitude faster than incremental maintenance).

\set table_name 'work_unit_embeddings_' :slug

DROP TABLE IF EXISTS :table_name;

CREATE TABLE :table_name (
  work_unit_id BIGINT PRIMARY KEY REFERENCES work_units(id) ON DELETE CASCADE,
  embedding vector(:dim) NOT NULL
);

\echo Created table for slug=:slug dim=:dim
