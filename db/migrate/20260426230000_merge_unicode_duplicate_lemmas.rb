class MergeUnicodeDuplicateLemmas < ActiveRecord::Migration[8.1]
  # Greek polytonic lemmas were imported with two different Unicode forms:
  # the deprecated precomposed polytonic block (U+1F71 GREEK SMALL LETTER
  # ALPHA WITH OXIA, etc.) and the modern monotonic codepoints (U+03AC
  # GREEK SMALL LETTER ALPHA WITH TONOS, etc.). They render identically
  # but have different byte sequences, so the lemmas table contained ~3,572
  # duplicate groups (~7,144 rows). User-visible symptom: a single Greek
  # word like θρόνος appeared twice in glosses with different frequencies.
  #
  # Both forms have the same NFD/NFC decomposition (base letter + accent),
  # so NFC normalization collapses them. This migration:
  #
  #   1. Groups all lemmas by (NFC-normalized lemma, language).
  #   2. For each duplicate group, picks the canonical row (highest
  #      frequency, ties → smallest id).
  #   3. Remaps every words.lemma_id reference to the canonical.
  #   4. Remaps lemmas.related_lemma_ids array entries to canonicals.
  #   5. Sums frequencies into the canonical row.
  #   6. NFC-normalizes the canonical row's `lemma` column.
  #   7. Deletes the duplicates.
  #   8. NFC-normalizes any remaining (non-duplicate) Greek/Hebrew lemmas
  #      so future import joins/queries are consistent.
  #   9. Adds a partial unique index on (lemma, language) to prevent
  #      recurrence — restricted to script-bearing languages so it
  #      doesn't conflict with existing transliteration rows.
  #
  # Idempotent re-run is not supported; this is a one-shot data fix.
  # PaperTrail is not engaged (admin-side bulk update, not user content).

  SCRIPT_LANGS = %w[grc el-koine el hbo he arc].freeze

  def up
    say_with_time "Building NFC-normalization map for #{SCRIPT_LANGS.join(', ')}" do
      # Pull all script-language lemmas in one shot, group in Ruby by
      # (NFC lemma, language). For each group: choose canonical, build the
      # remap. Remaps are written to a temp table so SQL can do the
      # bulk row updates.
      conn = ActiveRecord::Base.connection
      conn.execute(<<~SQL)
        CREATE TEMP TABLE lemma_dup_map (
          old_id      bigint PRIMARY KEY,
          canonical_id bigint NOT NULL,
          nfc_lemma   text   NOT NULL
        ) ON COMMIT DROP;
        CREATE INDEX ON lemma_dup_map (canonical_id);
      SQL

      rows = conn.exec_query(<<~SQL).rows
        SELECT id, lemma, language, COALESCE(frequency, 0)
        FROM lemmas
        WHERE language IN (#{SCRIPT_LANGS.map { |l| conn.quote(l) }.join(',')})
          AND lemma IS NOT NULL
      SQL

      groups = Hash.new { |h, k| h[k] = [] }
      rows.each do |id, lemma, lang, freq|
        nfc = lemma.unicode_normalize(:nfc)
        groups[[nfc, lang]] << { id: id.to_i, freq: freq.to_i }
      end

      n_groups_dup = 0
      n_rows_to_delete = 0
      n_rows_to_normalize = 0
      values = []

      groups.each do |(nfc, _lang), members|
        # Canonical pick: highest freq, ties → smallest id.
        canonical = members.max_by { |m| [m[:freq], -m[:id]] }
        members.each do |m|
          # Even non-duplicate members get an entry — we use this map
          # to NFC-normalize the lemma column at the end.
          values << "(#{m[:id]}, #{canonical[:id]}, #{conn.quote(nfc)})"
          n_rows_to_normalize += 1
          n_rows_to_delete += 1 if m[:id] != canonical[:id]
        end
        n_groups_dup += 1 if members.size > 1
      end

      # Bulk insert in chunks (Postgres has a parameter limit per statement).
      values.each_slice(2000) do |chunk|
        conn.execute("INSERT INTO lemma_dup_map (old_id, canonical_id, nfc_lemma) VALUES #{chunk.join(',')}")
      end

      say "groups (any): #{groups.size}, dup groups: #{n_groups_dup}, " \
          "rows to delete: #{n_rows_to_delete}, rows to NFC-normalize: #{n_rows_to_normalize}"
    end

    say_with_time "Sum frequencies into canonicals" do
      execute(<<~SQL)
        UPDATE lemmas l
           SET frequency = sub.total_freq
          FROM (
            SELECT m.canonical_id, SUM(COALESCE(src.frequency, 0))::int AS total_freq
            FROM lemma_dup_map m
            JOIN lemmas src ON src.id = m.old_id
            GROUP BY m.canonical_id
            HAVING COUNT(*) > 1
          ) sub
         WHERE l.id = sub.canonical_id
      SQL
    end

    say_with_time "Remap words.lemma_id" do
      execute(<<~SQL)
        UPDATE words w
           SET lemma_id = m.canonical_id
          FROM lemma_dup_map m
         WHERE w.lemma_id = m.old_id
           AND w.lemma_id <> m.canonical_id
      SQL
    end

    say_with_time "Remap lemmas.related_lemma_ids array entries" do
      # For each lemma whose related_lemma_ids array contains any id that
      # has a different canonical, rebuild the array using the map.
      # related_lemma_ids is integer[]; lemma_dup_map ids are bigint, so
      # we cast both sides of the && and the rebuilt array back to int[].
      execute(<<~SQL)
        UPDATE lemmas l
           SET related_lemma_ids = COALESCE((
             SELECT array_agg(DISTINCT COALESCE(m.canonical_id, x)::integer)
               FROM unnest(l.related_lemma_ids) x
          LEFT JOIN lemma_dup_map m ON m.old_id = x
           ), '{}'::integer[])
         WHERE l.related_lemma_ids && (
                 SELECT array_agg(old_id::integer) FROM lemma_dup_map
                 WHERE old_id <> canonical_id
               )
      SQL
    end

    say_with_time "Delete duplicate (non-canonical) lemmas" do
      # Must run BEFORE NFC-normalizing the canonical — if the canonical
      # is in legacy-precomposed form and a non-canonical sibling is
      # already in NFC form, renaming the canonical would collide on the
      # existing (language, lemma) unique index. Removing siblings first
      # frees the NFC form for the canonical to claim.
      execute(<<~SQL)
        DELETE FROM lemmas
         WHERE id IN (SELECT old_id FROM lemma_dup_map WHERE old_id <> canonical_id)
      SQL
    end

    say_with_time "NFC-normalize canonical lemmas" do
      execute(<<~SQL)
        UPDATE lemmas l
           SET lemma = m.nfc_lemma
          FROM lemma_dup_map m
         WHERE l.id = m.canonical_id
           AND l.lemma <> m.nfc_lemma
      SQL
    end

    # No new unique index needed: the existing index_lemmas_on_language_and_lemma
    # (UNIQUE on (language, lemma) over the whole table) already enforces this.
    # Combined with the new before_validation NFC normalizer in app/models/lemma.rb,
    # future imports can't recreate the legacy/NFC pair.
  end

  def down
    # The merge is destructive — duplicates can't be reconstructed without
    # re-running the importer.
    say "Down migration is a no-op; duplicate lemma rows are not restored. " \
        "Re-run the lexicon import to repopulate."
  end
end
