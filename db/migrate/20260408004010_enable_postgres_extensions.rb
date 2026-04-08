class EnablePostgresExtensions < ActiveRecord::Migration[8.1]
  # Required Postgres extensions for Open Scriptorium.
  #
  # btree_gist  — lets GIST indexes mix btree-indexable columns with range
  #               columns. We use it on cross_references for fast
  #               (work_id, range &&) overlap queries.
  # pg_trgm     — trigram similarity for fuzzy lemma / title search.
  # ltree       — hierarchical paths for work_units (book → chapter → verse,
  #               or commentary book → section → paragraph) without recursive
  #               CTEs on every breadcrumb query.
  # unaccent    — accent-insensitive search across Greek/Latin/etc.
  def change
    enable_extension "btree_gist"
    enable_extension "pg_trgm"
    enable_extension "ltree"
    enable_extension "unaccent"
  end
end
