class CleanupLemmaLanguageCorruption < ActiveRecord::Migration[8.1]
  # One-time cleanup of damage caused by the (now-patched)
  # MaculaLemmaFixImporter bug: it queried `words.strongs_number = '<bare>'`
  # without filtering by the work's language, then either repointed
  # cross-language words at the wrong-language lemma or — worse — picked
  # the most-used lemma row for that bare number and OVERWROTE its
  # `lemma`/`normalized`/`primary_gloss` columns with content from the
  # opposite language. Both Hebrew and Greek directions were affected.
  #
  # This migration:
  #
  #   1. NULLs `words.lemma_id` for every word in a Greek-only work that
  #      currently points at a Hebrew/Aramaic lemma (and vice versa for
  #      Hebrew works). Those pointers will be repopulated correctly on
  #      the next MaculaLemmaFixImporter run, which is now language-scoped.
  #
  #   2. Identifies "corrupted" lemma rows where the script of the
  #      `lemma` text disagrees with the `language` column (e.g. a row
  #      with language='hbo' whose lemma is "γένεσις"). These rows had
  #      their text overwritten by the bad importer run. After step 1
  #      they have no words pointing at them.
  #
  #   3. Removes those corrupt lemma ids from any `related_lemma_ids`
  #      array references on other lemmas, then deletes the corrupt rows.
  #
  # Re-running MaculaLemmaFixImporter (post-deploy) repopulates the words
  # this migration NULLed out, now correctly scoped by language.

  GREEK_LANGS  = %w[el-koine grc].freeze
  HEBREW_LANGS = %w[hbo he arc].freeze

  # Postgres regex character classes for the two scripts.
  # Greek: U+0370-U+03FF (basic) + U+1F00-U+1FFF (extended polytonic).
  # Hebrew: U+0590-U+05FF + U+FB1D-U+FB4F (presentation forms).
  GREEK_REGEX  = '[\\u0370-\\u03ff\\u1f00-\\u1fff]'
  HEBREW_REGEX = '[\\u0590-\\u05ff\\ufb1d-\\ufb4f]'

  def up
    say_with_time "NULL out cross-language words.lemma_id pointers" do
      glang = GREEK_LANGS.map  { |l| ActiveRecord::Base.connection.quote(l) }.join(",")
      hlang = HEBREW_LANGS.map { |l| ActiveRecord::Base.connection.quote(l) }.join(",")

      # Greek-only works pointing at non-Greek lemmas
      n_g = ActiveRecord::Base.connection.update(<<~SQL)
        UPDATE words w
           SET lemma_id = NULL
          FROM works wk, lemmas l
         WHERE w.work_id = wk.id
           AND w.lemma_id = l.id
           AND wk.language IN (#{glang})
           AND l.language NOT IN (#{glang})
      SQL
      say "  greek words pointing at non-greek lemmas → NULL: #{n_g}"

      # Hebrew/Aramaic-only works pointing at non-Hebrew lemmas
      n_h = ActiveRecord::Base.connection.update(<<~SQL)
        UPDATE words w
           SET lemma_id = NULL
          FROM works wk, lemmas l
         WHERE w.work_id = wk.id
           AND w.lemma_id = l.id
           AND wk.language IN (#{hlang})
           AND l.language NOT IN (#{hlang})
      SQL
      say "  hebrew words pointing at non-hebrew lemmas → NULL: #{n_h}"
    end

    say_with_time "Identify corrupt lemma rows (script disagrees with language)" do
      # Build the set of corrupt lemma ids in a temp table so subsequent
      # statements (related_lemma_ids cleanup, DELETE) can reference it.
      ActiveRecord::Base.connection.execute(<<~SQL)
        CREATE TEMP TABLE corrupt_lemmas ON COMMIT DROP AS
        SELECT id FROM lemmas
         WHERE (language IN ('hbo','he','arc') AND lemma ~ E'#{GREEK_REGEX}')
            OR (language IN ('el-koine','grc') AND lemma ~ E'#{HEBREW_REGEX}')
      SQL
      n = ActiveRecord::Base.connection.select_value("SELECT count(*) FROM corrupt_lemmas").to_i
      say "  corrupt lemma rows identified: #{n}"
    end

    say_with_time "NULL words still pointing at corrupt lemmas (intra-language)" do
      # Step 1 above only catches cross-language pointers. A separate
      # case: a word's work and lemma agree on language, but the lemma
      # row itself has script-corrupted text in its `lemma` column.
      # Without this, the DELETE below trips the words.lemma_id FK.
      n = ActiveRecord::Base.connection.update(<<~SQL)
        UPDATE words SET lemma_id = NULL
        WHERE lemma_id IN (SELECT id FROM corrupt_lemmas)
      SQL
      say "  words pointing at corrupt rows → NULL: #{n}"
    end

    say_with_time "Strip corrupt ids from related_lemma_ids arrays" do
      ActiveRecord::Base.connection.execute(<<~SQL)
        UPDATE lemmas l
           SET related_lemma_ids = COALESCE((
             SELECT array_agg(x ORDER BY x)
               FROM unnest(l.related_lemma_ids) x
              WHERE x NOT IN (SELECT id FROM corrupt_lemmas)
           ), '{}'::integer[])
         WHERE l.related_lemma_ids && (SELECT array_agg(id::integer) FROM corrupt_lemmas)
      SQL
    end

    say_with_time "DELETE corrupt lemma rows" do
      # Safety: if any words still reference them (shouldn't, after step
      # 1), the FK constraint will fail and we'll know to investigate.
      n = ActiveRecord::Base.connection.delete(<<~SQL)
        DELETE FROM lemmas WHERE id IN (SELECT id FROM corrupt_lemmas)
      SQL
      say "  deleted: #{n}"
    end
  end

  def down
    say "Down migration is a no-op. Re-run MaculaLemmaFixImporter and " \
        "(if needed) StepLexiconImporter to repopulate."
  end
end
