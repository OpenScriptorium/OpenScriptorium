class AddLemmaSearchIndexes < ActiveRecord::Migration[8.1]
  # CrossLanguageSearch's Pass 1 does `primary_gloss ~* '\bword\b'` and Pass 3
  # does `to_tsvector('english', COALESCE(senses::text, '')) @@ tsquery`.
  # Neither was indexed, so both fell back to sequential scans across ~30K
  # lemma rows and dominated multi-word search latency (160-280ms each).
  #
  # Adding:
  #   - GIN trigram on `primary_gloss` so `~*` (and `ILIKE`) can use an index.
  #   - GIN FTS on the `senses::text` tsvector expression.
  #
  # Both are non-concurrent because a) lemmas is small and b) we want this
  # to apply during a normal deploy, not as a separate concurrent build.

  disable_ddl_transaction!

  def up
    # Trigram on primary_gloss accelerates Pass 1's `~*` regex (~50ms → indexed).
    execute <<~SQL
      CREATE INDEX IF NOT EXISTS idx_lemmas_primary_gloss_trgm
        ON lemmas USING gin (primary_gloss gin_trgm_ops)
    SQL

    # FTS on senses::text accelerates Pass 3 (~150ms → indexed).
    # Expression-index form because senses is jsonb; we cast to text for FTS.
    execute <<~SQL
      CREATE INDEX IF NOT EXISTS idx_lemmas_senses_fts
        ON lemmas USING gin (to_tsvector('english', COALESCE(senses::text, '')))
    SQL
  end

  def down
    execute "DROP INDEX IF EXISTS idx_lemmas_senses_fts"
    execute "DROP INDEX IF EXISTS idx_lemmas_primary_gloss_trgm"
  end
end
