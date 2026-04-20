class CreateSearchInfrastructure < ActiveRecord::Migration[8.1]
  def up
    # ---------------------------------------------------------------
    # 1. Custom text search configurations
    # ---------------------------------------------------------------
    # scriptorium_simple: no stemming — for Hebrew, Greek, Aramaic, Latin.
    # Uses unaccent to strip diacritics before the simple dictionary.
    execute <<~SQL
      CREATE TEXT SEARCH CONFIGURATION scriptorium_simple (COPY = simple);
      ALTER TEXT SEARCH CONFIGURATION scriptorium_simple
        ALTER MAPPING FOR asciiword, asciihword, hword_asciipart, word, hword, hword_part
        WITH unaccent, simple;
    SQL

    # scriptorium_english: English stemmer with unaccent.
    execute <<~SQL
      CREATE TEXT SEARCH CONFIGURATION scriptorium_english (COPY = english);
      ALTER TEXT SEARCH CONFIGURATION scriptorium_english
        ALTER MAPPING FOR asciiword, asciihword, hword_asciipart, word, hword, hword_part
        WITH unaccent, english_stem;
    SQL

    # ---------------------------------------------------------------
    # 2. Hebrew diacritic stripping function
    # ---------------------------------------------------------------
    # Strips nikud (U+0591–U+05BD, U+05BF–U+05C7) so pointed and
    # unpointed Hebrew match the same tsvector.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION strip_hebrew_points(text) RETURNS text AS $$
        SELECT regexp_replace($1, '[\u0591-\u05BD\u05BF-\u05C7]', '', 'g');
      $$ LANGUAGE sql IMMUTABLE STRICT;
    SQL

    # ---------------------------------------------------------------
    # 3. body_tsvector column on work_units
    # ---------------------------------------------------------------
    add_column :work_units, :body_tsvector, :tsvector

    # ---------------------------------------------------------------
    # 4. Trigger to populate body_tsvector on INSERT/UPDATE
    # ---------------------------------------------------------------
    # Looks up works.language to pick the right FTS config.
    # Hebrew/Aramaic bodies are stripped of nikud before vectorizing.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION work_units_tsvector_trigger() RETURNS trigger AS $$
      DECLARE
        work_lang text;
        fts_config regconfig;
        body_text text;
      BEGIN
        SELECT w.language INTO work_lang
          FROM works w WHERE w.id = NEW.work_id;

        CASE
          WHEN work_lang IN ('he', 'hbo', 'arc') THEN
            fts_config := 'scriptorium_simple'::regconfig;
            body_text := strip_hebrew_points(COALESCE(NEW.body, ''));
          WHEN work_lang LIKE 'el%' OR work_lang IN ('grc', 'la') THEN
            fts_config := 'scriptorium_simple'::regconfig;
            body_text := COALESCE(NEW.body, '');
          WHEN work_lang = 'fr' THEN
            fts_config := 'french'::regconfig;
            body_text := COALESCE(NEW.body, '');
          WHEN work_lang = 'de' THEN
            fts_config := 'german'::regconfig;
            body_text := COALESCE(NEW.body, '');
          ELSE
            fts_config := 'scriptorium_english'::regconfig;
            body_text := COALESCE(NEW.body, '');
        END CASE;

        NEW.body_tsvector := to_tsvector(fts_config, body_text);
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER work_units_tsvector_update
        BEFORE INSERT OR UPDATE OF body ON work_units
        FOR EACH ROW EXECUTE FUNCTION work_units_tsvector_trigger();
    SQL

    # ---------------------------------------------------------------
    # 5. GIN index on body_tsvector
    # ---------------------------------------------------------------
    add_index :work_units, :body_tsvector, using: :gin, name: "idx_work_units_body_tsvector"

    # ---------------------------------------------------------------
    # 6. Backfill existing rows
    # ---------------------------------------------------------------
    # Touch every row so the trigger fires and populates body_tsvector.
    execute <<~SQL
      UPDATE work_units SET body = body;
    SQL

    # ---------------------------------------------------------------
    # 7. Trigram indexes on words
    # ---------------------------------------------------------------
    execute <<~SQL
      CREATE INDEX idx_words_normalized_trgm ON words USING gin (normalized gin_trgm_ops);
      CREATE INDEX idx_words_surface_trgm ON words USING gin (surface gin_trgm_ops);
    SQL
    add_index :words, [:work_id, :morph_code], name: "idx_words_work_morph"

    # ---------------------------------------------------------------
    # 8. Trigram indexes on lemmas + FTS on primary_gloss
    # ---------------------------------------------------------------
    execute <<~SQL
      CREATE INDEX idx_lemmas_transliteration_trgm ON lemmas USING gin (transliteration gin_trgm_ops);
      CREATE INDEX idx_lemmas_normalized_trgm ON lemmas USING gin (normalized gin_trgm_ops);
      CREATE INDEX idx_lemmas_gloss_fts ON lemmas USING gin (to_tsvector('english', COALESCE(primary_gloss, '')));
    SQL

    # ---------------------------------------------------------------
    # 9. Trigram index on canonical_refs.sbl_citation
    # ---------------------------------------------------------------
    execute <<~SQL
      CREATE INDEX idx_canonical_refs_citation_trgm ON canonical_refs USING gin (sbl_citation gin_trgm_ops);
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS work_units_tsvector_update ON work_units;"
    execute "DROP FUNCTION IF EXISTS work_units_tsvector_trigger();"
    execute "DROP FUNCTION IF EXISTS strip_hebrew_points(text);"

    remove_index :work_units, name: "idx_work_units_body_tsvector", if_exists: true
    remove_column :work_units, :body_tsvector, if_exists: true

    execute "DROP INDEX IF EXISTS idx_words_normalized_trgm;"
    execute "DROP INDEX IF EXISTS idx_words_surface_trgm;"
    remove_index :words, name: "idx_words_work_morph", if_exists: true

    execute "DROP INDEX IF EXISTS idx_lemmas_transliteration_trgm;"
    execute "DROP INDEX IF EXISTS idx_lemmas_normalized_trgm;"
    execute "DROP INDEX IF EXISTS idx_lemmas_gloss_fts;"
    execute "DROP INDEX IF EXISTS idx_canonical_refs_citation_trgm;"

    execute "DROP TEXT SEARCH CONFIGURATION IF EXISTS scriptorium_simple;"
    execute "DROP TEXT SEARCH CONFIGURATION IF EXISTS scriptorium_english;"
  end
end
