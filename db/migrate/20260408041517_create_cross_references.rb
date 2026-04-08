class CreateCrossReferences < ActiveRecord::Migration[8.1]
  # Cross-references between any two passages in the corpus, stored at
  # the canonical layer (NOT at the work layer) so each fact is
  # language- and edition-independent.
  #
  # Both source_range and target_range are int4range over canonical_refs.ord
  # so a cross-reference can target a single verse, a chapter, or a whole
  # book uniformly. GIST indexes make overlap queries (`&&`) O(log n).
  def change
    create_table :cross_references do |t|
      t.references :source_canonical_work, null: false,
                                            foreign_key: { to_table: :canonical_works }
      t.references :target_canonical_work, null: false,
                                            foreign_key: { to_table: :canonical_works }
      t.string     :relationship_type, null: false
        # quotes, alludes_to, parallels, comments_on, fulfills,
        # contradicts, paraphrases, cites_as_authority, ...
      t.decimal    :confidence, precision: 4, scale: 3
      t.string     :source_dataset
        # 'OpenBible.info', 'TSK', 'user_submitted', 'programmatic_LXX_NT_match'
      t.text       :notes
      t.references :created_by_user, foreign_key: { to_table: :users }
      t.datetime   :approved_at
      t.references :approved_by_user, foreign_key: { to_table: :users }
      t.string     :status, null: false, default: "approved"
        # proposed, approved, rejected
      t.timestamps
    end

    # int4range columns added via raw SQL because Rails doesn't have
    # first-class support for range types in the migration DSL yet.
    execute <<~SQL
      ALTER TABLE cross_references
        ADD COLUMN source_range int4range NOT NULL,
        ADD COLUMN target_range int4range NOT NULL;
    SQL

    # GIST indexes for fast overlap queries. btree_gist (enabled in our
    # earlier extensions migration) lets us combine canonical_work_id
    # (btree) with the range column in a single index.
    execute <<~SQL
      CREATE INDEX idx_xrefs_source_range
        ON cross_references USING gist (source_canonical_work_id, source_range);
      CREATE INDEX idx_xrefs_target_range
        ON cross_references USING gist (target_canonical_work_id, target_range);
    SQL

    add_index :cross_references, :status
    add_index :cross_references, :source_dataset
  end
end
