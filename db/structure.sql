SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: btree_gist; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;


--
-- Name: EXTENSION btree_gist; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION btree_gist IS 'support for indexing common datatypes in GiST';


--
-- Name: ltree; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS ltree WITH SCHEMA public;


--
-- Name: EXTENSION ltree; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION ltree IS 'data type for hierarchical tree-like structures';


--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: unaccent; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA public;


--
-- Name: EXTENSION unaccent; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION unaccent IS 'text search dictionary that removes accents';


--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


--
-- Name: expand_bible_synonyms(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.expand_bible_synonyms(query text) RETURNS text
    LANGUAGE sql STABLE
    AS $$
  SELECT string_agg(COALESCE(s.target, w.word), ' ' ORDER BY w.ord)
  FROM unnest(string_to_array(lower(query), ' ')) WITH ORDINALITY AS w(word, ord)
  LEFT JOIN bible_synonyms s ON s.source = w.word
$$;


--
-- Name: strip_hebrew_points(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.strip_hebrew_points(text) RETURNS text
    LANGUAGE sql IMMUTABLE STRICT
    AS $_$
  SELECT regexp_replace($1, '[֑-ֽֿ-ׇ]', '', 'g');
$_$;


--
-- Name: work_units_tsvector_trigger(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.work_units_tsvector_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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
$$;


--
-- Name: scriptorium_english; Type: TEXT SEARCH CONFIGURATION; Schema: public; Owner: -
--

CREATE TEXT SEARCH CONFIGURATION public.scriptorium_english (
    PARSER = pg_catalog."default" );

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_english
    ADD MAPPING FOR asciiword WITH public.unaccent, english_stem;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_english
    ADD MAPPING FOR word WITH public.unaccent, english_stem;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_english
    ADD MAPPING FOR numword WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_english
    ADD MAPPING FOR email WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_english
    ADD MAPPING FOR url WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_english
    ADD MAPPING FOR host WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_english
    ADD MAPPING FOR sfloat WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_english
    ADD MAPPING FOR version WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_english
    ADD MAPPING FOR hword_numpart WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_english
    ADD MAPPING FOR hword_part WITH public.unaccent, english_stem;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_english
    ADD MAPPING FOR hword_asciipart WITH public.unaccent, english_stem;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_english
    ADD MAPPING FOR numhword WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_english
    ADD MAPPING FOR asciihword WITH public.unaccent, english_stem;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_english
    ADD MAPPING FOR hword WITH public.unaccent, english_stem;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_english
    ADD MAPPING FOR url_path WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_english
    ADD MAPPING FOR file WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_english
    ADD MAPPING FOR "float" WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_english
    ADD MAPPING FOR "int" WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_english
    ADD MAPPING FOR uint WITH simple;


--
-- Name: scriptorium_simple; Type: TEXT SEARCH CONFIGURATION; Schema: public; Owner: -
--

CREATE TEXT SEARCH CONFIGURATION public.scriptorium_simple (
    PARSER = pg_catalog."default" );

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_simple
    ADD MAPPING FOR asciiword WITH public.unaccent, simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_simple
    ADD MAPPING FOR word WITH public.unaccent, simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_simple
    ADD MAPPING FOR numword WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_simple
    ADD MAPPING FOR email WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_simple
    ADD MAPPING FOR url WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_simple
    ADD MAPPING FOR host WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_simple
    ADD MAPPING FOR sfloat WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_simple
    ADD MAPPING FOR version WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_simple
    ADD MAPPING FOR hword_numpart WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_simple
    ADD MAPPING FOR hword_part WITH public.unaccent, simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_simple
    ADD MAPPING FOR hword_asciipart WITH public.unaccent, simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_simple
    ADD MAPPING FOR numhword WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_simple
    ADD MAPPING FOR asciihword WITH public.unaccent, simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_simple
    ADD MAPPING FOR hword WITH public.unaccent, simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_simple
    ADD MAPPING FOR url_path WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_simple
    ADD MAPPING FOR file WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_simple
    ADD MAPPING FOR "float" WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_simple
    ADD MAPPING FOR "int" WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.scriptorium_simple
    ADD MAPPING FOR uint WITH simple;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: alignment_group_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.alignment_group_members (
    id bigint NOT NULL,
    alignment_group_id bigint NOT NULL,
    word_id bigint NOT NULL,
    role character varying NOT NULL,
    "position" integer,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    import_run_id bigint
);


--
-- Name: alignment_group_members_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.alignment_group_members_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: alignment_group_members_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.alignment_group_members_id_seq OWNED BY public.alignment_group_members.id;


--
-- Name: alignment_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.alignment_groups (
    id bigint NOT NULL,
    canonical_ref_id bigint NOT NULL,
    source_work_id bigint NOT NULL,
    target_work_id bigint NOT NULL,
    alignment_type character varying DEFAULT 'literal'::character varying NOT NULL,
    confidence numeric(4,3),
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    import_run_id bigint
);


--
-- Name: alignment_groups_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.alignment_groups_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: alignment_groups_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.alignment_groups_id_seq OWNED BY public.alignment_groups.id;


--
-- Name: annotations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.annotations (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    canonical_work_id bigint NOT NULL,
    body_markdown text NOT NULL,
    body_html text,
    status character varying DEFAULT 'draft'::character varying NOT NULL,
    reviewed_by_user_id bigint,
    reviewed_at timestamp(6) without time zone,
    review_notes text,
    visibility character varying DEFAULT 'private'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    canonical_range int4range NOT NULL
);


--
-- Name: annotations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.annotations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: annotations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.annotations_id_seq OWNED BY public.annotations.id;


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: authors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.authors (
    id bigint NOT NULL,
    slug character varying NOT NULL,
    name character varying NOT NULL,
    sort_name character varying,
    latin_name character varying,
    native_name character varying,
    birth_year integer,
    death_year integer,
    era character varying,
    tradition character varying,
    bio text,
    wikipedia_url character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: authors_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.authors_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: authors_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.authors_id_seq OWNED BY public.authors.id;


--
-- Name: bible_synonyms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bible_synonyms (
    source character varying NOT NULL,
    target character varying NOT NULL
);


--
-- Name: bookmarks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bookmarks (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    canonical_work_id bigint NOT NULL,
    canonical_ref_id bigint NOT NULL,
    label character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: bookmarks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bookmarks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bookmarks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.bookmarks_id_seq OWNED BY public.bookmarks.id;


--
-- Name: canonical_refs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.canonical_refs (
    id bigint NOT NULL,
    canonical_work_id bigint NOT NULL,
    ord integer NOT NULL,
    display_label character varying NOT NULL,
    osis_id character varying,
    hierarchy integer[] DEFAULT '{}'::integer[] NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    import_run_id bigint,
    sbl_citation character varying,
    xref_count integer DEFAULT 0 NOT NULL
);


--
-- Name: canonical_refs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.canonical_refs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: canonical_refs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.canonical_refs_id_seq OWNED BY public.canonical_refs.id;


--
-- Name: canonical_works; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.canonical_works (
    id bigint NOT NULL,
    slug character varying NOT NULL,
    title character varying NOT NULL,
    native_title character varying,
    versification_scheme_id bigint,
    parent_canonical_work_id bigint,
    "position" integer,
    testament character varying,
    osis_book_id character varying,
    description text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    sbl_abbreviation character varying,
    citation_format character varying DEFAULT 'scripture'::character varying,
    book_key character varying NOT NULL,
    alternate_titles jsonb
);


--
-- Name: canonical_works_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.canonical_works_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: canonical_works_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.canonical_works_id_seq OWNED BY public.canonical_works.id;


--
-- Name: cross_references; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cross_references (
    id bigint NOT NULL,
    source_canonical_work_id bigint NOT NULL,
    target_canonical_work_id bigint NOT NULL,
    relationship_type character varying NOT NULL,
    confidence numeric(4,3),
    source_dataset character varying,
    notes text,
    created_by_user_id bigint,
    approved_at timestamp(6) without time zone,
    approved_by_user_id bigint,
    status character varying DEFAULT 'approved'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    source_range int4range NOT NULL,
    target_range int4range NOT NULL,
    import_run_id bigint
);


--
-- Name: cross_references_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.cross_references_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cross_references_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.cross_references_id_seq OWNED BY public.cross_references.id;


--
-- Name: import_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.import_runs (
    id bigint NOT NULL,
    importer_class character varying NOT NULL,
    source_url character varying,
    source_revision character varying,
    source_byte_count bigint,
    source_format character varying,
    started_at timestamp(6) without time zone NOT NULL,
    finished_at timestamp(6) without time zone,
    status character varying DEFAULT 'running'::character varying NOT NULL,
    error_message text,
    error_backtrace text,
    stats jsonb DEFAULT '{}'::jsonb NOT NULL,
    options jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: import_runs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.import_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: import_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.import_runs_id_seq OWNED BY public.import_runs.id;


--
-- Name: invitations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invitations (
    id bigint NOT NULL,
    code character varying NOT NULL,
    created_by_user_id bigint NOT NULL,
    used_by_user_id bigint,
    used_at timestamp(6) without time zone,
    expires_at timestamp(6) without time zone,
    notes text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: invitations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.invitations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: invitations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.invitations_id_seq OWNED BY public.invitations.id;


--
-- Name: lemmas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lemmas (
    id bigint NOT NULL,
    language character varying NOT NULL,
    lemma character varying NOT NULL,
    normalized character varying NOT NULL,
    primary_gloss character varying,
    part_of_speech character varying,
    frequency integer DEFAULT 0 NOT NULL,
    lexicon_entry_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    import_run_id bigint,
    etymology text,
    transliteration character varying,
    senses jsonb DEFAULT '[]'::jsonb NOT NULL,
    related_lemma_ids integer[] DEFAULT '{}'::integer[] NOT NULL,
    frequency_by_book jsonb DEFAULT '{}'::jsonb NOT NULL,
    attested_period character varying
);


--
-- Name: lemmas_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.lemmas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: lemmas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.lemmas_id_seq OWNED BY public.lemmas.id;


--
-- Name: licenses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.licenses (
    id bigint NOT NULL,
    name character varying NOT NULL,
    spdx_id character varying,
    url character varying,
    attribution_required boolean DEFAULT false NOT NULL,
    attribution_template character varying,
    description text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: licenses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.licenses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: licenses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.licenses_id_seq OWNED BY public.licenses.id;


--
-- Name: manuscripts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.manuscripts (
    id bigint NOT NULL,
    siglum character varying NOT NULL,
    name character varying,
    date_text character varying,
    date_year_estimate integer,
    family character varying,
    language character varying,
    location character varying,
    description text,
    image_url character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    import_run_id bigint,
    gregory_aland_number character varying,
    intf_liste_number character varying,
    material character varying,
    format character varying,
    extent_description text,
    lacunae jsonb DEFAULT '[]'::jsonb NOT NULL,
    shelfmark character varying
);


--
-- Name: manuscripts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.manuscripts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: manuscripts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.manuscripts_id_seq OWNED BY public.manuscripts.id;


--
-- Name: participant_references; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.participant_references (
    id bigint NOT NULL,
    word_id bigint NOT NULL,
    referent_word_id bigint,
    work_unit_id bigint NOT NULL,
    ref_type character varying NOT NULL,
    macula_source_id character varying,
    macula_target_id character varying,
    import_run_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: participant_references_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.participant_references_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: participant_references_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.participant_references_id_seq OWNED BY public.participant_references.id;


--
-- Name: passage_alias_names; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.passage_alias_names (
    id bigint NOT NULL,
    passage_alias_id bigint NOT NULL,
    name character varying NOT NULL,
    locale character varying DEFAULT 'en'::character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: passage_alias_names_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.passage_alias_names_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: passage_alias_names_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.passage_alias_names_id_seq OWNED BY public.passage_alias_names.id;


--
-- Name: passage_aliases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.passage_aliases (
    id bigint NOT NULL,
    ref character varying NOT NULL,
    import_run_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: passage_aliases_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.passage_aliases_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: passage_aliases_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.passage_aliases_id_seq OWNED BY public.passage_aliases.id;


--
-- Name: pericopes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pericopes (
    id bigint NOT NULL,
    canonical_work_id bigint NOT NULL,
    source_dataset character varying NOT NULL,
    name character varying NOT NULL,
    native_name character varying,
    pericope_type character varying,
    sequence_number integer,
    description text,
    import_run_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    canonical_range int4range NOT NULL,
    tradition character varying,
    name_embedding_qwen3 public.vector(1024)
);


--
-- Name: pericopes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.pericopes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: pericopes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.pericopes_id_seq OWNED BY public.pericopes.id;


--
-- Name: personal_notes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.personal_notes (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    canonical_work_id bigint NOT NULL,
    body_markdown text NOT NULL,
    body_html text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    canonical_range int4range NOT NULL
);


--
-- Name: personal_notes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.personal_notes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: personal_notes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.personal_notes_id_seq OWNED BY public.personal_notes.id;


--
-- Name: reading_plan_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reading_plan_entries (
    id bigint NOT NULL,
    reading_plan_id bigint NOT NULL,
    day integer NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    canonical_work_id bigint NOT NULL,
    label character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    canonical_range int4range NOT NULL
);


--
-- Name: reading_plan_entries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.reading_plan_entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: reading_plan_entries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.reading_plan_entries_id_seq OWNED BY public.reading_plan_entries.id;


--
-- Name: reading_plan_progress; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reading_plan_progress (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    reading_plan_id bigint NOT NULL,
    reading_plan_entry_id bigint NOT NULL,
    completed_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: reading_plan_progress_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.reading_plan_progress_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: reading_plan_progress_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.reading_plan_progress_id_seq OWNED BY public.reading_plan_progress.id;


--
-- Name: reading_plans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reading_plans (
    id bigint NOT NULL,
    slug character varying NOT NULL,
    title character varying NOT NULL,
    description text,
    created_by_user_id bigint NOT NULL,
    is_public boolean DEFAULT false NOT NULL,
    length_days integer,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: reading_plans_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.reading_plans_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: reading_plans_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.reading_plans_id_seq OWNED BY public.reading_plans.id;


--
-- Name: reading_witnesses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reading_witnesses (
    id bigint NOT NULL,
    reading_id bigint NOT NULL,
    manuscript_id bigint NOT NULL,
    certainty character varying,
    notes text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    correction_layer character varying,
    folio character varying,
    column_number integer,
    line_number integer,
    is_lacuna boolean DEFAULT false NOT NULL,
    is_supplement boolean DEFAULT false NOT NULL,
    import_run_id bigint
);


--
-- Name: reading_witnesses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.reading_witnesses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: reading_witnesses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.reading_witnesses_id_seq OWNED BY public.reading_witnesses.id;


--
-- Name: readings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.readings (
    id bigint NOT NULL,
    variant_unit_id bigint NOT NULL,
    text text NOT NULL,
    normalized_text text,
    notes text,
    is_base boolean DEFAULT false NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    import_run_id bigint
);


--
-- Name: readings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.readings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: readings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.readings_id_seq OWNED BY public.readings.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: search_concept_verses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.search_concept_verses (
    id bigint NOT NULL,
    search_concept_id bigint NOT NULL,
    canonical_ref_id bigint NOT NULL,
    role character varying DEFAULT 'signature'::character varying NOT NULL,
    weight numeric(4,2) DEFAULT 1.0 NOT NULL,
    import_run_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: search_concept_verses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.search_concept_verses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: search_concept_verses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.search_concept_verses_id_seq OWNED BY public.search_concept_verses.id;


--
-- Name: search_concepts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.search_concepts (
    id bigint NOT NULL,
    name character varying NOT NULL,
    description text,
    aliases text[] DEFAULT '{}'::text[] NOT NULL,
    kind character varying NOT NULL,
    import_run_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: search_concepts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.search_concepts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: search_concepts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.search_concepts_id_seq OWNED BY public.search_concepts.id;


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    ip_address character varying,
    user_agent character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sessions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sessions_id_seq OWNED BY public.sessions.id;


--
-- Name: settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.settings (
    id bigint NOT NULL,
    key character varying NOT NULL,
    value text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: settings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.settings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: settings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.settings_id_seq OWNED BY public.settings.id;


--
-- Name: syntax_nodes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.syntax_nodes (
    id bigint NOT NULL,
    work_id bigint NOT NULL,
    work_unit_id bigint NOT NULL,
    parent_id bigint,
    path public.ltree NOT NULL,
    node_class character varying NOT NULL,
    node_type character varying,
    clause_type character varying,
    rule character varying,
    role character varying,
    start_position integer,
    end_position integer,
    depth integer DEFAULT 0,
    import_run_id bigint,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: syntax_nodes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.syntax_nodes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: syntax_nodes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.syntax_nodes_id_seq OWNED BY public.syntax_nodes.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    email_address character varying NOT NULL,
    password_digest character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    display_name character varying,
    bio text,
    role character varying DEFAULT 'visitor'::character varying NOT NULL,
    invited_by_user_id bigint,
    invited_at timestamp(6) without time zone,
    email_confirmed_at timestamp(6) without time zone,
    preferences jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: variant_units; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.variant_units (
    id bigint NOT NULL,
    canonical_ref_id bigint NOT NULL,
    position_within_ref integer DEFAULT 1 NOT NULL,
    base_reading_id bigint,
    notes text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    lemma_text text,
    context_before text,
    context_after text,
    variant_type character varying,
    import_run_id bigint
);


--
-- Name: variant_units_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.variant_units_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: variant_units_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.variant_units_id_seq OWNED BY public.variant_units.id;


--
-- Name: versification_mappings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.versification_mappings (
    id bigint NOT NULL,
    from_scheme_id bigint NOT NULL,
    from_canonical_ref_id bigint NOT NULL,
    to_scheme_id bigint NOT NULL,
    to_canonical_ref_id bigint NOT NULL,
    mapping_type character varying NOT NULL,
    notes text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: versification_mappings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.versification_mappings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: versification_mappings_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.versification_mappings_id_seq OWNED BY public.versification_mappings.id;


--
-- Name: versification_schemes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.versification_schemes (
    id bigint NOT NULL,
    code character varying NOT NULL,
    display_name character varying NOT NULL,
    description text,
    source_url character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: versification_schemes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.versification_schemes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: versification_schemes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.versification_schemes_id_seq OWNED BY public.versification_schemes.id;


--
-- Name: versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.versions (
    id bigint NOT NULL,
    whodunnit character varying,
    created_at timestamp(6) without time zone,
    item_id bigint NOT NULL,
    item_type character varying NOT NULL,
    event character varying NOT NULL,
    object text
);


--
-- Name: versions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.versions_id_seq OWNED BY public.versions.id;


--
-- Name: words; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.words (
    id bigint NOT NULL,
    work_id bigint NOT NULL,
    work_unit_id bigint NOT NULL,
    "position" integer NOT NULL,
    surface character varying NOT NULL,
    normalized character varying,
    lemma_id bigint,
    morph_code character varying,
    strongs_number character varying,
    notes jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    import_run_id bigint,
    syntax_node_id bigint,
    role character varying,
    sdbh character varying,
    lexdomain character varying,
    coredomain character varying
);


--
-- Name: words_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.words_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: words_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.words_id_seq OWNED BY public.words.id;


--
-- Name: work_authorships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.work_authorships (
    id bigint NOT NULL,
    work_id bigint NOT NULL,
    author_id bigint NOT NULL,
    role character varying NOT NULL,
    "position" integer,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: work_authorships_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.work_authorships_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: work_authorships_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.work_authorships_id_seq OWNED BY public.work_authorships.id;


--
-- Name: work_unit_embeddings_qwen3_06b; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.work_unit_embeddings_qwen3_06b (
    work_unit_id bigint NOT NULL,
    embedding public.vector(1024) NOT NULL
);


--
-- Name: work_unit_notes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.work_unit_notes (
    id bigint NOT NULL,
    work_unit_id bigint NOT NULL,
    import_run_id bigint,
    position_in_unit integer DEFAULT 0 NOT NULL,
    note_type character varying NOT NULL,
    body text NOT NULL,
    anchor_text text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: work_unit_notes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.work_unit_notes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: work_unit_notes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.work_unit_notes_id_seq OWNED BY public.work_unit_notes.id;


--
-- Name: work_units; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.work_units (
    id bigint NOT NULL,
    work_id bigint NOT NULL,
    ord integer NOT NULL,
    parent_id bigint,
    "position" integer,
    label character varying,
    hierarchy_path public.ltree,
    canonical_ref_id bigint,
    canonical_alignment_type character varying DEFAULT 'exact'::character varying,
    canonical_alignment_confidence numeric(4,3),
    body text,
    markup jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    import_run_id bigint,
    body_tsvector tsvector
);


--
-- Name: work_units_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.work_units_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: work_units_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.work_units_id_seq OWNED BY public.work_units.id;


--
-- Name: works; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.works (
    id bigint NOT NULL,
    slug character varying NOT NULL,
    title character varying NOT NULL,
    native_title character varying,
    work_type character varying NOT NULL,
    language character varying,
    era character varying,
    genre character varying,
    license_id bigint NOT NULL,
    default_versification_scheme_id bigint,
    source_url character varying,
    import_notes text,
    publication_year integer,
    description text,
    has_word_data boolean DEFAULT false NOT NULL,
    has_apparatus boolean DEFAULT false NOT NULL,
    imported_at timestamp(6) without time zone,
    last_imported_at timestamp(6) without time zone,
    source_revision character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    import_run_id bigint,
    pericope_traditions character varying[] DEFAULT '{}'::character varying[],
    traditions character varying[] DEFAULT '{}'::character varying[],
    cached_feature_flags character varying[] DEFAULT '{}'::character varying[]
);


--
-- Name: works_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.works_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: works_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.works_id_seq OWNED BY public.works.id;


--
-- Name: alignment_group_members id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alignment_group_members ALTER COLUMN id SET DEFAULT nextval('public.alignment_group_members_id_seq'::regclass);


--
-- Name: alignment_groups id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alignment_groups ALTER COLUMN id SET DEFAULT nextval('public.alignment_groups_id_seq'::regclass);


--
-- Name: annotations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.annotations ALTER COLUMN id SET DEFAULT nextval('public.annotations_id_seq'::regclass);


--
-- Name: authors id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authors ALTER COLUMN id SET DEFAULT nextval('public.authors_id_seq'::regclass);


--
-- Name: bookmarks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookmarks ALTER COLUMN id SET DEFAULT nextval('public.bookmarks_id_seq'::regclass);


--
-- Name: canonical_refs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.canonical_refs ALTER COLUMN id SET DEFAULT nextval('public.canonical_refs_id_seq'::regclass);


--
-- Name: canonical_works id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.canonical_works ALTER COLUMN id SET DEFAULT nextval('public.canonical_works_id_seq'::regclass);


--
-- Name: cross_references id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cross_references ALTER COLUMN id SET DEFAULT nextval('public.cross_references_id_seq'::regclass);


--
-- Name: import_runs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_runs ALTER COLUMN id SET DEFAULT nextval('public.import_runs_id_seq'::regclass);


--
-- Name: invitations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitations ALTER COLUMN id SET DEFAULT nextval('public.invitations_id_seq'::regclass);


--
-- Name: lemmas id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lemmas ALTER COLUMN id SET DEFAULT nextval('public.lemmas_id_seq'::regclass);


--
-- Name: licenses id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.licenses ALTER COLUMN id SET DEFAULT nextval('public.licenses_id_seq'::regclass);


--
-- Name: manuscripts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.manuscripts ALTER COLUMN id SET DEFAULT nextval('public.manuscripts_id_seq'::regclass);


--
-- Name: participant_references id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.participant_references ALTER COLUMN id SET DEFAULT nextval('public.participant_references_id_seq'::regclass);


--
-- Name: passage_alias_names id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.passage_alias_names ALTER COLUMN id SET DEFAULT nextval('public.passage_alias_names_id_seq'::regclass);


--
-- Name: passage_aliases id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.passage_aliases ALTER COLUMN id SET DEFAULT nextval('public.passage_aliases_id_seq'::regclass);


--
-- Name: pericopes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pericopes ALTER COLUMN id SET DEFAULT nextval('public.pericopes_id_seq'::regclass);


--
-- Name: personal_notes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_notes ALTER COLUMN id SET DEFAULT nextval('public.personal_notes_id_seq'::regclass);


--
-- Name: reading_plan_entries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reading_plan_entries ALTER COLUMN id SET DEFAULT nextval('public.reading_plan_entries_id_seq'::regclass);


--
-- Name: reading_plan_progress id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reading_plan_progress ALTER COLUMN id SET DEFAULT nextval('public.reading_plan_progress_id_seq'::regclass);


--
-- Name: reading_plans id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reading_plans ALTER COLUMN id SET DEFAULT nextval('public.reading_plans_id_seq'::regclass);


--
-- Name: reading_witnesses id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reading_witnesses ALTER COLUMN id SET DEFAULT nextval('public.reading_witnesses_id_seq'::regclass);


--
-- Name: readings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.readings ALTER COLUMN id SET DEFAULT nextval('public.readings_id_seq'::regclass);


--
-- Name: search_concept_verses id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_concept_verses ALTER COLUMN id SET DEFAULT nextval('public.search_concept_verses_id_seq'::regclass);


--
-- Name: search_concepts id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_concepts ALTER COLUMN id SET DEFAULT nextval('public.search_concepts_id_seq'::regclass);


--
-- Name: sessions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions ALTER COLUMN id SET DEFAULT nextval('public.sessions_id_seq'::regclass);


--
-- Name: settings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settings ALTER COLUMN id SET DEFAULT nextval('public.settings_id_seq'::regclass);


--
-- Name: syntax_nodes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.syntax_nodes ALTER COLUMN id SET DEFAULT nextval('public.syntax_nodes_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: variant_units id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.variant_units ALTER COLUMN id SET DEFAULT nextval('public.variant_units_id_seq'::regclass);


--
-- Name: versification_mappings id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.versification_mappings ALTER COLUMN id SET DEFAULT nextval('public.versification_mappings_id_seq'::regclass);


--
-- Name: versification_schemes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.versification_schemes ALTER COLUMN id SET DEFAULT nextval('public.versification_schemes_id_seq'::regclass);


--
-- Name: versions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.versions ALTER COLUMN id SET DEFAULT nextval('public.versions_id_seq'::regclass);


--
-- Name: words id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.words ALTER COLUMN id SET DEFAULT nextval('public.words_id_seq'::regclass);


--
-- Name: work_authorships id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_authorships ALTER COLUMN id SET DEFAULT nextval('public.work_authorships_id_seq'::regclass);


--
-- Name: work_unit_notes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_unit_notes ALTER COLUMN id SET DEFAULT nextval('public.work_unit_notes_id_seq'::regclass);


--
-- Name: work_units id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_units ALTER COLUMN id SET DEFAULT nextval('public.work_units_id_seq'::regclass);


--
-- Name: works id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.works ALTER COLUMN id SET DEFAULT nextval('public.works_id_seq'::regclass);


--
-- Name: alignment_group_members alignment_group_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alignment_group_members
    ADD CONSTRAINT alignment_group_members_pkey PRIMARY KEY (id);


--
-- Name: alignment_groups alignment_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alignment_groups
    ADD CONSTRAINT alignment_groups_pkey PRIMARY KEY (id);


--
-- Name: annotations annotations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.annotations
    ADD CONSTRAINT annotations_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: authors authors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.authors
    ADD CONSTRAINT authors_pkey PRIMARY KEY (id);


--
-- Name: bookmarks bookmarks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookmarks
    ADD CONSTRAINT bookmarks_pkey PRIMARY KEY (id);


--
-- Name: canonical_refs canonical_refs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.canonical_refs
    ADD CONSTRAINT canonical_refs_pkey PRIMARY KEY (id);


--
-- Name: canonical_works canonical_works_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.canonical_works
    ADD CONSTRAINT canonical_works_pkey PRIMARY KEY (id);


--
-- Name: cross_references cross_references_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cross_references
    ADD CONSTRAINT cross_references_pkey PRIMARY KEY (id);


--
-- Name: import_runs import_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_runs
    ADD CONSTRAINT import_runs_pkey PRIMARY KEY (id);


--
-- Name: invitations invitations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitations
    ADD CONSTRAINT invitations_pkey PRIMARY KEY (id);


--
-- Name: lemmas lemmas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lemmas
    ADD CONSTRAINT lemmas_pkey PRIMARY KEY (id);


--
-- Name: licenses licenses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.licenses
    ADD CONSTRAINT licenses_pkey PRIMARY KEY (id);


--
-- Name: manuscripts manuscripts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.manuscripts
    ADD CONSTRAINT manuscripts_pkey PRIMARY KEY (id);


--
-- Name: participant_references participant_references_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.participant_references
    ADD CONSTRAINT participant_references_pkey PRIMARY KEY (id);


--
-- Name: passage_alias_names passage_alias_names_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.passage_alias_names
    ADD CONSTRAINT passage_alias_names_pkey PRIMARY KEY (id);


--
-- Name: passage_aliases passage_aliases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.passage_aliases
    ADD CONSTRAINT passage_aliases_pkey PRIMARY KEY (id);


--
-- Name: pericopes pericopes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pericopes
    ADD CONSTRAINT pericopes_pkey PRIMARY KEY (id);


--
-- Name: personal_notes personal_notes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_notes
    ADD CONSTRAINT personal_notes_pkey PRIMARY KEY (id);


--
-- Name: reading_plan_entries reading_plan_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reading_plan_entries
    ADD CONSTRAINT reading_plan_entries_pkey PRIMARY KEY (id);


--
-- Name: reading_plan_progress reading_plan_progress_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reading_plan_progress
    ADD CONSTRAINT reading_plan_progress_pkey PRIMARY KEY (id);


--
-- Name: reading_plans reading_plans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reading_plans
    ADD CONSTRAINT reading_plans_pkey PRIMARY KEY (id);


--
-- Name: reading_witnesses reading_witnesses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reading_witnesses
    ADD CONSTRAINT reading_witnesses_pkey PRIMARY KEY (id);


--
-- Name: readings readings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.readings
    ADD CONSTRAINT readings_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: search_concept_verses search_concept_verses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_concept_verses
    ADD CONSTRAINT search_concept_verses_pkey PRIMARY KEY (id);


--
-- Name: search_concepts search_concepts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_concepts
    ADD CONSTRAINT search_concepts_pkey PRIMARY KEY (id);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: settings settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settings
    ADD CONSTRAINT settings_pkey PRIMARY KEY (id);


--
-- Name: syntax_nodes syntax_nodes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.syntax_nodes
    ADD CONSTRAINT syntax_nodes_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: variant_units variant_units_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.variant_units
    ADD CONSTRAINT variant_units_pkey PRIMARY KEY (id);


--
-- Name: versification_mappings versification_mappings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.versification_mappings
    ADD CONSTRAINT versification_mappings_pkey PRIMARY KEY (id);


--
-- Name: versification_schemes versification_schemes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.versification_schemes
    ADD CONSTRAINT versification_schemes_pkey PRIMARY KEY (id);


--
-- Name: versions versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.versions
    ADD CONSTRAINT versions_pkey PRIMARY KEY (id);


--
-- Name: words words_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.words
    ADD CONSTRAINT words_pkey PRIMARY KEY (id);


--
-- Name: work_authorships work_authorships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_authorships
    ADD CONSTRAINT work_authorships_pkey PRIMARY KEY (id);


--
-- Name: work_unit_embeddings_qwen3_06b work_unit_embeddings_qwen3_06b_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_unit_embeddings_qwen3_06b
    ADD CONSTRAINT work_unit_embeddings_qwen3_06b_pkey PRIMARY KEY (work_unit_id);


--
-- Name: work_unit_notes work_unit_notes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_unit_notes
    ADD CONSTRAINT work_unit_notes_pkey PRIMARY KEY (id);


--
-- Name: work_units work_units_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_units
    ADD CONSTRAINT work_units_pkey PRIMARY KEY (id);


--
-- Name: works works_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.works
    ADD CONSTRAINT works_pkey PRIMARY KEY (id);


--
-- Name: idx_align_groups_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_align_groups_lookup ON public.alignment_groups USING btree (canonical_ref_id, source_work_id, target_work_id);


--
-- Name: idx_align_members_grouping; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_align_members_grouping ON public.alignment_group_members USING btree (alignment_group_id, role, "position");


--
-- Name: idx_align_members_word; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_align_members_word ON public.alignment_group_members USING btree (word_id);


--
-- Name: idx_annotations_range; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_annotations_range ON public.annotations USING gist (canonical_work_id, canonical_range);


--
-- Name: idx_canonical_refs_citation_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_canonical_refs_citation_trgm ON public.canonical_refs USING gin (sbl_citation public.gin_trgm_ops);


--
-- Name: idx_concept_verses_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_concept_verses_unique ON public.search_concept_verses USING btree (search_concept_id, canonical_ref_id);


--
-- Name: idx_lemmas_gloss_fts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lemmas_gloss_fts ON public.lemmas USING gin (to_tsvector('english'::regconfig, (COALESCE(primary_gloss, ''::character varying))::text));


--
-- Name: idx_lemmas_normalized_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lemmas_normalized_trgm ON public.lemmas USING gin (normalized public.gin_trgm_ops);


--
-- Name: idx_lemmas_transliteration_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lemmas_transliteration_trgm ON public.lemmas USING gin (transliteration public.gin_trgm_ops);


--
-- Name: idx_on_canonical_ref_id_position_within_ref_374ea7e394; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_on_canonical_ref_id_position_within_ref_374ea7e394 ON public.variant_units USING btree (canonical_ref_id, position_within_ref);


--
-- Name: idx_participant_refs_referent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_participant_refs_referent ON public.participant_references USING btree (referent_word_id, ref_type);


--
-- Name: idx_passage_alias_names_lower; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_passage_alias_names_lower ON public.passage_alias_names USING btree (lower((name)::text));


--
-- Name: idx_passage_alias_names_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_passage_alias_names_trgm ON public.passage_alias_names USING gin (lower((name)::text) public.gin_trgm_ops);


--
-- Name: idx_pericopes_name_embedding_qwen3_hnsw; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pericopes_name_embedding_qwen3_hnsw ON public.pericopes USING hnsw (name_embedding_qwen3 public.vector_cosine_ops) WHERE (name_embedding_qwen3 IS NOT NULL);


--
-- Name: idx_pericopes_range; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pericopes_range ON public.pericopes USING gist (canonical_work_id, canonical_range);


--
-- Name: idx_personal_notes_range; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_personal_notes_range ON public.personal_notes USING gist (user_id, canonical_work_id, canonical_range);


--
-- Name: idx_rp_entries_order; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rp_entries_order ON public.reading_plan_entries USING btree (reading_plan_id, day, "position");


--
-- Name: idx_rp_progress_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rp_progress_unique ON public.reading_plan_progress USING btree (user_id, reading_plan_entry_id);


--
-- Name: idx_v11n_mappings_from; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_v11n_mappings_from ON public.versification_mappings USING btree (from_scheme_id, from_canonical_ref_id, to_scheme_id);


--
-- Name: idx_v11n_mappings_to; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_v11n_mappings_to ON public.versification_mappings USING btree (to_scheme_id, to_canonical_ref_id, from_scheme_id);


--
-- Name: idx_words_normalized_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_words_normalized_trgm ON public.words USING gin (normalized public.gin_trgm_ops);


--
-- Name: idx_words_surface_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_words_surface_trgm ON public.words USING gin (surface public.gin_trgm_ops);


--
-- Name: idx_words_work_morph; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_words_work_morph ON public.words USING btree (work_id, morph_code);


--
-- Name: idx_work_units_body_tsvector; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_work_units_body_tsvector ON public.work_units USING gin (body_tsvector);


--
-- Name: idx_work_units_work_canonical_ref; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_work_units_work_canonical_ref ON public.work_units USING btree (work_id, canonical_ref_id);


--
-- Name: idx_wue_qwen3_06b_hnsw; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wue_qwen3_06b_hnsw ON public.work_unit_embeddings_qwen3_06b USING hnsw (embedding public.vector_cosine_ops);


--
-- Name: idx_xrefs_source_range; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_xrefs_source_range ON public.cross_references USING gist (source_canonical_work_id, source_range);


--
-- Name: idx_xrefs_source_status_dataset; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_xrefs_source_status_dataset ON public.cross_references USING btree (source_canonical_work_id, status, source_dataset);


--
-- Name: idx_xrefs_target_range; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_xrefs_target_range ON public.cross_references USING gist (target_canonical_work_id, target_range);


--
-- Name: idx_xrefs_target_status_dataset; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_xrefs_target_status_dataset ON public.cross_references USING btree (target_canonical_work_id, status, source_dataset);


--
-- Name: index_alignment_group_members_on_alignment_group_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_alignment_group_members_on_alignment_group_id ON public.alignment_group_members USING btree (alignment_group_id);


--
-- Name: index_alignment_group_members_on_import_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_alignment_group_members_on_import_run_id ON public.alignment_group_members USING btree (import_run_id);


--
-- Name: index_alignment_group_members_on_word_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_alignment_group_members_on_word_id ON public.alignment_group_members USING btree (word_id);


--
-- Name: index_alignment_groups_on_canonical_ref_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_alignment_groups_on_canonical_ref_id ON public.alignment_groups USING btree (canonical_ref_id);


--
-- Name: index_alignment_groups_on_import_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_alignment_groups_on_import_run_id ON public.alignment_groups USING btree (import_run_id);


--
-- Name: index_alignment_groups_on_source_work_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_alignment_groups_on_source_work_id ON public.alignment_groups USING btree (source_work_id);


--
-- Name: index_alignment_groups_on_target_work_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_alignment_groups_on_target_work_id ON public.alignment_groups USING btree (target_work_id);


--
-- Name: index_annotations_on_canonical_work_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_annotations_on_canonical_work_id ON public.annotations USING btree (canonical_work_id);


--
-- Name: index_annotations_on_reviewed_by_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_annotations_on_reviewed_by_user_id ON public.annotations USING btree (reviewed_by_user_id);


--
-- Name: index_annotations_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_annotations_on_status ON public.annotations USING btree (status);


--
-- Name: index_annotations_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_annotations_on_user_id ON public.annotations USING btree (user_id);


--
-- Name: index_annotations_on_user_id_and_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_annotations_on_user_id_and_status ON public.annotations USING btree (user_id, status);


--
-- Name: index_authors_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_authors_on_slug ON public.authors USING btree (slug);


--
-- Name: index_authors_on_sort_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_authors_on_sort_name ON public.authors USING btree (sort_name);


--
-- Name: index_authors_on_tradition; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_authors_on_tradition ON public.authors USING btree (tradition);


--
-- Name: index_bible_synonyms_on_source; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_bible_synonyms_on_source ON public.bible_synonyms USING btree (source);


--
-- Name: index_bookmarks_on_canonical_ref_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_bookmarks_on_canonical_ref_id ON public.bookmarks USING btree (canonical_ref_id);


--
-- Name: index_bookmarks_on_canonical_work_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_bookmarks_on_canonical_work_id ON public.bookmarks USING btree (canonical_work_id);


--
-- Name: index_bookmarks_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_bookmarks_on_user_id ON public.bookmarks USING btree (user_id);


--
-- Name: index_bookmarks_on_user_id_and_canonical_ref_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_bookmarks_on_user_id_and_canonical_ref_id ON public.bookmarks USING btree (user_id, canonical_ref_id);


--
-- Name: index_canonical_refs_on_canonical_work_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_canonical_refs_on_canonical_work_id ON public.canonical_refs USING btree (canonical_work_id);


--
-- Name: index_canonical_refs_on_canonical_work_id_and_ord; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_canonical_refs_on_canonical_work_id_and_ord ON public.canonical_refs USING btree (canonical_work_id, ord);


--
-- Name: index_canonical_refs_on_hierarchy; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_canonical_refs_on_hierarchy ON public.canonical_refs USING gin (hierarchy);


--
-- Name: index_canonical_refs_on_import_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_canonical_refs_on_import_run_id ON public.canonical_refs USING btree (import_run_id);


--
-- Name: index_canonical_refs_on_osis_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_canonical_refs_on_osis_id ON public.canonical_refs USING btree (osis_id);


--
-- Name: index_canonical_refs_on_sbl_citation; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_canonical_refs_on_sbl_citation ON public.canonical_refs USING btree (sbl_citation);


--
-- Name: index_canonical_works_on_book_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_canonical_works_on_book_key ON public.canonical_works USING btree (book_key);


--
-- Name: index_canonical_works_on_osis_book_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_canonical_works_on_osis_book_id ON public.canonical_works USING btree (osis_book_id);


--
-- Name: index_canonical_works_on_parent_canonical_work_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_canonical_works_on_parent_canonical_work_id ON public.canonical_works USING btree (parent_canonical_work_id);


--
-- Name: index_canonical_works_on_parent_canonical_work_id_and_position; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_canonical_works_on_parent_canonical_work_id_and_position ON public.canonical_works USING btree (parent_canonical_work_id, "position");


--
-- Name: index_canonical_works_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_canonical_works_on_slug ON public.canonical_works USING btree (slug);


--
-- Name: index_canonical_works_on_testament; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_canonical_works_on_testament ON public.canonical_works USING btree (testament);


--
-- Name: index_canonical_works_on_versification_scheme_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_canonical_works_on_versification_scheme_id ON public.canonical_works USING btree (versification_scheme_id);


--
-- Name: index_cross_references_on_import_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_cross_references_on_import_run_id ON public.cross_references USING btree (import_run_id);


--
-- Name: index_cross_references_on_source_canonical_work_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_cross_references_on_source_canonical_work_id ON public.cross_references USING btree (source_canonical_work_id);


--
-- Name: index_cross_references_on_source_dataset; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_cross_references_on_source_dataset ON public.cross_references USING btree (source_dataset);


--
-- Name: index_cross_references_on_target_canonical_work_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_cross_references_on_target_canonical_work_id ON public.cross_references USING btree (target_canonical_work_id);


--
-- Name: index_import_runs_on_importer_class; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_import_runs_on_importer_class ON public.import_runs USING btree (importer_class);


--
-- Name: index_import_runs_on_started_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_import_runs_on_started_at ON public.import_runs USING btree (started_at);


--
-- Name: index_import_runs_on_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_import_runs_on_status ON public.import_runs USING btree (status);


--
-- Name: index_invitations_on_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_invitations_on_code ON public.invitations USING btree (code);


--
-- Name: index_invitations_on_created_by_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_invitations_on_created_by_user_id ON public.invitations USING btree (created_by_user_id);


--
-- Name: index_invitations_on_used_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_invitations_on_used_at ON public.invitations USING btree (used_at);


--
-- Name: index_invitations_on_used_by_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_invitations_on_used_by_user_id ON public.invitations USING btree (used_by_user_id);


--
-- Name: index_lemmas_on_import_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_lemmas_on_import_run_id ON public.lemmas USING btree (import_run_id);


--
-- Name: index_lemmas_on_language_and_lemma; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_lemmas_on_language_and_lemma ON public.lemmas USING btree (language, lemma);


--
-- Name: index_lemmas_on_language_and_normalized; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_lemmas_on_language_and_normalized ON public.lemmas USING btree (language, normalized);


--
-- Name: index_lemmas_on_lexicon_entry_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_lemmas_on_lexicon_entry_id ON public.lemmas USING btree (lexicon_entry_id);


--
-- Name: index_lemmas_on_related_lemma_ids; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_lemmas_on_related_lemma_ids ON public.lemmas USING gin (related_lemma_ids);


--
-- Name: index_licenses_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_licenses_on_name ON public.licenses USING btree (name);


--
-- Name: index_licenses_on_spdx_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_licenses_on_spdx_id ON public.licenses USING btree (spdx_id);


--
-- Name: index_manuscripts_on_family; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_manuscripts_on_family ON public.manuscripts USING btree (family);


--
-- Name: index_manuscripts_on_gregory_aland_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_manuscripts_on_gregory_aland_number ON public.manuscripts USING btree (gregory_aland_number);


--
-- Name: index_manuscripts_on_import_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_manuscripts_on_import_run_id ON public.manuscripts USING btree (import_run_id);


--
-- Name: index_manuscripts_on_intf_liste_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_manuscripts_on_intf_liste_number ON public.manuscripts USING btree (intf_liste_number);


--
-- Name: index_manuscripts_on_siglum; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_manuscripts_on_siglum ON public.manuscripts USING btree (siglum);


--
-- Name: index_participant_references_on_import_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_participant_references_on_import_run_id ON public.participant_references USING btree (import_run_id);


--
-- Name: index_participant_references_on_referent_word_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_participant_references_on_referent_word_id ON public.participant_references USING btree (referent_word_id);


--
-- Name: index_participant_references_on_word_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_participant_references_on_word_id ON public.participant_references USING btree (word_id);


--
-- Name: index_participant_references_on_work_unit_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_participant_references_on_work_unit_id ON public.participant_references USING btree (work_unit_id);


--
-- Name: index_participant_references_on_work_unit_id_and_ref_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_participant_references_on_work_unit_id_and_ref_type ON public.participant_references USING btree (work_unit_id, ref_type);


--
-- Name: index_passage_alias_names_on_passage_alias_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_passage_alias_names_on_passage_alias_id ON public.passage_alias_names USING btree (passage_alias_id);


--
-- Name: index_passage_aliases_on_import_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_passage_aliases_on_import_run_id ON public.passage_aliases USING btree (import_run_id);


--
-- Name: index_pericopes_on_canonical_work_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_pericopes_on_canonical_work_id ON public.pericopes USING btree (canonical_work_id);


--
-- Name: index_pericopes_on_import_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_pericopes_on_import_run_id ON public.pericopes USING btree (import_run_id);


--
-- Name: index_pericopes_on_pericope_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_pericopes_on_pericope_type ON public.pericopes USING btree (pericope_type);


--
-- Name: index_pericopes_on_source_dataset; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_pericopes_on_source_dataset ON public.pericopes USING btree (source_dataset);


--
-- Name: index_pericopes_on_source_dataset_and_sequence_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_pericopes_on_source_dataset_and_sequence_number ON public.pericopes USING btree (source_dataset, sequence_number);


--
-- Name: index_pericopes_on_tradition; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_pericopes_on_tradition ON public.pericopes USING btree (tradition);


--
-- Name: index_personal_notes_on_canonical_work_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_personal_notes_on_canonical_work_id ON public.personal_notes USING btree (canonical_work_id);


--
-- Name: index_personal_notes_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_personal_notes_on_user_id ON public.personal_notes USING btree (user_id);


--
-- Name: index_reading_plan_entries_on_canonical_work_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reading_plan_entries_on_canonical_work_id ON public.reading_plan_entries USING btree (canonical_work_id);


--
-- Name: index_reading_plan_entries_on_reading_plan_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reading_plan_entries_on_reading_plan_id ON public.reading_plan_entries USING btree (reading_plan_id);


--
-- Name: index_reading_plan_progress_on_reading_plan_entry_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reading_plan_progress_on_reading_plan_entry_id ON public.reading_plan_progress USING btree (reading_plan_entry_id);


--
-- Name: index_reading_plan_progress_on_reading_plan_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reading_plan_progress_on_reading_plan_id ON public.reading_plan_progress USING btree (reading_plan_id);


--
-- Name: index_reading_plan_progress_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reading_plan_progress_on_user_id ON public.reading_plan_progress USING btree (user_id);


--
-- Name: index_reading_plans_on_created_by_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reading_plans_on_created_by_user_id ON public.reading_plans USING btree (created_by_user_id);


--
-- Name: index_reading_plans_on_is_public; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reading_plans_on_is_public ON public.reading_plans USING btree (is_public);


--
-- Name: index_reading_plans_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_reading_plans_on_slug ON public.reading_plans USING btree (slug);


--
-- Name: index_reading_witnesses_on_import_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reading_witnesses_on_import_run_id ON public.reading_witnesses USING btree (import_run_id);


--
-- Name: index_reading_witnesses_on_manuscript_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reading_witnesses_on_manuscript_id ON public.reading_witnesses USING btree (manuscript_id);


--
-- Name: index_reading_witnesses_on_reading_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_reading_witnesses_on_reading_id ON public.reading_witnesses USING btree (reading_id);


--
-- Name: index_reading_witnesses_on_reading_id_and_manuscript_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_reading_witnesses_on_reading_id_and_manuscript_id ON public.reading_witnesses USING btree (reading_id, manuscript_id);


--
-- Name: index_readings_on_import_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_readings_on_import_run_id ON public.readings USING btree (import_run_id);


--
-- Name: index_readings_on_variant_unit_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_readings_on_variant_unit_id ON public.readings USING btree (variant_unit_id);


--
-- Name: index_readings_on_variant_unit_id_and_is_base; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_readings_on_variant_unit_id_and_is_base ON public.readings USING btree (variant_unit_id, is_base);


--
-- Name: index_search_concept_verses_on_canonical_ref_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_search_concept_verses_on_canonical_ref_id ON public.search_concept_verses USING btree (canonical_ref_id);


--
-- Name: index_search_concept_verses_on_import_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_search_concept_verses_on_import_run_id ON public.search_concept_verses USING btree (import_run_id);


--
-- Name: index_search_concept_verses_on_search_concept_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_search_concept_verses_on_search_concept_id ON public.search_concept_verses USING btree (search_concept_id);


--
-- Name: index_search_concepts_on_aliases; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_search_concepts_on_aliases ON public.search_concepts USING gin (aliases);


--
-- Name: index_search_concepts_on_import_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_search_concepts_on_import_run_id ON public.search_concepts USING btree (import_run_id);


--
-- Name: index_search_concepts_on_kind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_search_concepts_on_kind ON public.search_concepts USING btree (kind);


--
-- Name: index_search_concepts_on_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_search_concepts_on_name ON public.search_concepts USING btree (name);


--
-- Name: index_sessions_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_sessions_on_user_id ON public.sessions USING btree (user_id);


--
-- Name: index_settings_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_settings_on_key ON public.settings USING btree (key);


--
-- Name: index_syntax_nodes_on_import_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_syntax_nodes_on_import_run_id ON public.syntax_nodes USING btree (import_run_id);


--
-- Name: index_syntax_nodes_on_node_class_and_node_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_syntax_nodes_on_node_class_and_node_type ON public.syntax_nodes USING btree (node_class, node_type);


--
-- Name: index_syntax_nodes_on_node_class_and_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_syntax_nodes_on_node_class_and_role ON public.syntax_nodes USING btree (node_class, role);


--
-- Name: index_syntax_nodes_on_parent_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_syntax_nodes_on_parent_id ON public.syntax_nodes USING btree (parent_id);


--
-- Name: index_syntax_nodes_on_path; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_syntax_nodes_on_path ON public.syntax_nodes USING gist (path);


--
-- Name: index_syntax_nodes_on_work_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_syntax_nodes_on_work_id ON public.syntax_nodes USING btree (work_id);


--
-- Name: index_syntax_nodes_on_work_unit_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_syntax_nodes_on_work_unit_id ON public.syntax_nodes USING btree (work_unit_id);


--
-- Name: index_syntax_nodes_on_work_unit_id_and_node_class; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_syntax_nodes_on_work_unit_id_and_node_class ON public.syntax_nodes USING btree (work_unit_id, node_class);


--
-- Name: index_users_on_email_address; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email_address ON public.users USING btree (email_address);


--
-- Name: index_users_on_invited_by_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_users_on_invited_by_user_id ON public.users USING btree (invited_by_user_id);


--
-- Name: index_users_on_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_users_on_role ON public.users USING btree (role);


--
-- Name: index_variant_units_on_base_reading_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_variant_units_on_base_reading_id ON public.variant_units USING btree (base_reading_id);


--
-- Name: index_variant_units_on_canonical_ref_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_variant_units_on_canonical_ref_id ON public.variant_units USING btree (canonical_ref_id);


--
-- Name: index_variant_units_on_import_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_variant_units_on_import_run_id ON public.variant_units USING btree (import_run_id);


--
-- Name: index_versification_mappings_on_from_canonical_ref_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_versification_mappings_on_from_canonical_ref_id ON public.versification_mappings USING btree (from_canonical_ref_id);


--
-- Name: index_versification_mappings_on_from_scheme_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_versification_mappings_on_from_scheme_id ON public.versification_mappings USING btree (from_scheme_id);


--
-- Name: index_versification_mappings_on_to_canonical_ref_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_versification_mappings_on_to_canonical_ref_id ON public.versification_mappings USING btree (to_canonical_ref_id);


--
-- Name: index_versification_mappings_on_to_scheme_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_versification_mappings_on_to_scheme_id ON public.versification_mappings USING btree (to_scheme_id);


--
-- Name: index_versification_schemes_on_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_versification_schemes_on_code ON public.versification_schemes USING btree (code);


--
-- Name: index_versions_on_item_type_and_item_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_versions_on_item_type_and_item_id ON public.versions USING btree (item_type, item_id);


--
-- Name: index_words_on_import_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_words_on_import_run_id ON public.words USING btree (import_run_id);


--
-- Name: index_words_on_lemma_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_words_on_lemma_id ON public.words USING btree (lemma_id);


--
-- Name: index_words_on_strongs_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_words_on_strongs_number ON public.words USING btree (strongs_number);


--
-- Name: index_words_on_syntax_node_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_words_on_syntax_node_id ON public.words USING btree (syntax_node_id);


--
-- Name: index_words_on_work_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_words_on_work_id ON public.words USING btree (work_id);


--
-- Name: index_words_on_work_unit_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_words_on_work_unit_id ON public.words USING btree (work_unit_id);


--
-- Name: index_words_on_work_unit_id_and_position; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_words_on_work_unit_id_and_position ON public.words USING btree (work_unit_id, "position");


--
-- Name: index_work_authorships_on_author_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_work_authorships_on_author_id ON public.work_authorships USING btree (author_id);


--
-- Name: index_work_authorships_on_work_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_work_authorships_on_work_id ON public.work_authorships USING btree (work_id);


--
-- Name: index_work_authorships_on_work_id_and_author_id_and_role; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_work_authorships_on_work_id_and_author_id_and_role ON public.work_authorships USING btree (work_id, author_id, role);


--
-- Name: index_work_unit_notes_on_import_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_work_unit_notes_on_import_run_id ON public.work_unit_notes USING btree (import_run_id);


--
-- Name: index_work_unit_notes_on_note_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_work_unit_notes_on_note_type ON public.work_unit_notes USING btree (note_type);


--
-- Name: index_work_unit_notes_on_work_unit_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_work_unit_notes_on_work_unit_id ON public.work_unit_notes USING btree (work_unit_id);


--
-- Name: index_work_unit_notes_on_work_unit_id_and_position_in_unit; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_work_unit_notes_on_work_unit_id_and_position_in_unit ON public.work_unit_notes USING btree (work_unit_id, position_in_unit);


--
-- Name: index_work_units_on_canonical_ref_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_work_units_on_canonical_ref_id ON public.work_units USING btree (canonical_ref_id);


--
-- Name: index_work_units_on_import_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_work_units_on_import_run_id ON public.work_units USING btree (import_run_id);


--
-- Name: index_work_units_on_parent_id_and_position; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_work_units_on_parent_id_and_position ON public.work_units USING btree (parent_id, "position");


--
-- Name: index_work_units_on_work_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_work_units_on_work_id ON public.work_units USING btree (work_id);


--
-- Name: index_work_units_on_work_id_and_ord; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_work_units_on_work_id_and_ord ON public.work_units USING btree (work_id, ord);


--
-- Name: index_works_on_default_versification_scheme_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_works_on_default_versification_scheme_id ON public.works USING btree (default_versification_scheme_id);


--
-- Name: index_works_on_import_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_works_on_import_run_id ON public.works USING btree (import_run_id);


--
-- Name: index_works_on_language; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_works_on_language ON public.works USING btree (language);


--
-- Name: index_works_on_license_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_works_on_license_id ON public.works USING btree (license_id);


--
-- Name: index_works_on_pericope_traditions; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_works_on_pericope_traditions ON public.works USING gin (pericope_traditions);


--
-- Name: index_works_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_works_on_slug ON public.works USING btree (slug);


--
-- Name: index_works_on_traditions; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_works_on_traditions ON public.works USING gin (traditions);


--
-- Name: index_works_on_work_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_works_on_work_type ON public.works USING btree (work_type);


--
-- Name: work_units work_units_tsvector_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER work_units_tsvector_update BEFORE INSERT OR UPDATE OF body ON public.work_units FOR EACH ROW EXECUTE FUNCTION public.work_units_tsvector_trigger();


--
-- Name: lemmas fk_rails_05aaa9177e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lemmas
    ADD CONSTRAINT fk_rails_05aaa9177e FOREIGN KEY (lexicon_entry_id) REFERENCES public.work_units(id);


--
-- Name: works fk_rails_0788ff6f39; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.works
    ADD CONSTRAINT fk_rails_0788ff6f39 FOREIGN KEY (default_versification_scheme_id) REFERENCES public.versification_schemes(id);


--
-- Name: versification_mappings fk_rails_079b219c1b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.versification_mappings
    ADD CONSTRAINT fk_rails_079b219c1b FOREIGN KEY (from_scheme_id) REFERENCES public.versification_schemes(id);


--
-- Name: work_authorships fk_rails_084ad11800; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_authorships
    ADD CONSTRAINT fk_rails_084ad11800 FOREIGN KEY (author_id) REFERENCES public.authors(id);


--
-- Name: words fk_rails_0af824940c; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.words
    ADD CONSTRAINT fk_rails_0af824940c FOREIGN KEY (import_run_id) REFERENCES public.import_runs(id);


--
-- Name: annotations fk_rails_11d410e004; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.annotations
    ADD CONSTRAINT fk_rails_11d410e004 FOREIGN KEY (canonical_work_id) REFERENCES public.canonical_works(id);


--
-- Name: versification_mappings fk_rails_14e7083ada; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.versification_mappings
    ADD CONSTRAINT fk_rails_14e7083ada FOREIGN KEY (to_scheme_id) REFERENCES public.versification_schemes(id);


--
-- Name: reading_plans fk_rails_157585ebe8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reading_plans
    ADD CONSTRAINT fk_rails_157585ebe8 FOREIGN KEY (created_by_user_id) REFERENCES public.users(id);


--
-- Name: invitations fk_rails_164f95b3aa; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitations
    ADD CONSTRAINT fk_rails_164f95b3aa FOREIGN KEY (used_by_user_id) REFERENCES public.users(id);


--
-- Name: alignment_groups fk_rails_183e6974d3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alignment_groups
    ADD CONSTRAINT fk_rails_183e6974d3 FOREIGN KEY (canonical_ref_id) REFERENCES public.canonical_refs(id);


--
-- Name: syntax_nodes fk_rails_1bc2ebc9b3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.syntax_nodes
    ADD CONSTRAINT fk_rails_1bc2ebc9b3 FOREIGN KEY (work_unit_id) REFERENCES public.work_units(id);


--
-- Name: pericopes fk_rails_1eca4714c6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pericopes
    ADD CONSTRAINT fk_rails_1eca4714c6 FOREIGN KEY (import_run_id) REFERENCES public.import_runs(id);


--
-- Name: reading_plan_entries fk_rails_21ca74d85d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reading_plan_entries
    ADD CONSTRAINT fk_rails_21ca74d85d FOREIGN KEY (reading_plan_id) REFERENCES public.reading_plans(id);


--
-- Name: participant_references fk_rails_24c37b6850; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.participant_references
    ADD CONSTRAINT fk_rails_24c37b6850 FOREIGN KEY (referent_word_id) REFERENCES public.words(id);


--
-- Name: lemmas fk_rails_2683a32070; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lemmas
    ADD CONSTRAINT fk_rails_2683a32070 FOREIGN KEY (import_run_id) REFERENCES public.import_runs(id);


--
-- Name: alignment_group_members fk_rails_2abc28faff; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alignment_group_members
    ADD CONSTRAINT fk_rails_2abc28faff FOREIGN KEY (word_id) REFERENCES public.words(id);


--
-- Name: reading_witnesses fk_rails_2b5a012ab5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reading_witnesses
    ADD CONSTRAINT fk_rails_2b5a012ab5 FOREIGN KEY (import_run_id) REFERENCES public.import_runs(id);


--
-- Name: work_units fk_rails_2f5df34105; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_units
    ADD CONSTRAINT fk_rails_2f5df34105 FOREIGN KEY (canonical_ref_id) REFERENCES public.canonical_refs(id);


--
-- Name: versification_mappings fk_rails_31557bada7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.versification_mappings
    ADD CONSTRAINT fk_rails_31557bada7 FOREIGN KEY (from_canonical_ref_id) REFERENCES public.canonical_refs(id);


--
-- Name: search_concepts fk_rails_378b479822; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_concepts
    ADD CONSTRAINT fk_rails_378b479822 FOREIGN KEY (import_run_id) REFERENCES public.import_runs(id);


--
-- Name: invitations fk_rails_3c94dfe5a4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitations
    ADD CONSTRAINT fk_rails_3c94dfe5a4 FOREIGN KEY (created_by_user_id) REFERENCES public.users(id);


--
-- Name: pericopes fk_rails_3df2ce5254; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pericopes
    ADD CONSTRAINT fk_rails_3df2ce5254 FOREIGN KEY (canonical_work_id) REFERENCES public.canonical_works(id);


--
-- Name: work_units fk_rails_3ed7e47eb7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_units
    ADD CONSTRAINT fk_rails_3ed7e47eb7 FOREIGN KEY (work_id) REFERENCES public.works(id);


--
-- Name: annotations fk_rails_4043df79bf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.annotations
    ADD CONSTRAINT fk_rails_4043df79bf FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: variant_units fk_rails_4267fb597a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.variant_units
    ADD CONSTRAINT fk_rails_4267fb597a FOREIGN KEY (import_run_id) REFERENCES public.import_runs(id);


--
-- Name: manuscripts fk_rails_4b4d8910f6; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.manuscripts
    ADD CONSTRAINT fk_rails_4b4d8910f6 FOREIGN KEY (import_run_id) REFERENCES public.import_runs(id);


--
-- Name: search_concept_verses fk_rails_4c8db1fae3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_concept_verses
    ADD CONSTRAINT fk_rails_4c8db1fae3 FOREIGN KEY (canonical_ref_id) REFERENCES public.canonical_refs(id);


--
-- Name: bookmarks fk_rails_51af58e045; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookmarks
    ADD CONSTRAINT fk_rails_51af58e045 FOREIGN KEY (canonical_work_id) REFERENCES public.canonical_works(id);


--
-- Name: reading_witnesses fk_rails_5a01348a33; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reading_witnesses
    ADD CONSTRAINT fk_rails_5a01348a33 FOREIGN KEY (manuscript_id) REFERENCES public.manuscripts(id);


--
-- Name: passage_alias_names fk_rails_5a50ea57f2; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.passage_alias_names
    ADD CONSTRAINT fk_rails_5a50ea57f2 FOREIGN KEY (passage_alias_id) REFERENCES public.passage_aliases(id);


--
-- Name: words fk_rails_647ed48285; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.words
    ADD CONSTRAINT fk_rails_647ed48285 FOREIGN KEY (syntax_node_id) REFERENCES public.syntax_nodes(id);


--
-- Name: reading_plan_progress fk_rails_6b63692bad; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reading_plan_progress
    ADD CONSTRAINT fk_rails_6b63692bad FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: search_concept_verses fk_rails_7034ba7eb7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_concept_verses
    ADD CONSTRAINT fk_rails_7034ba7eb7 FOREIGN KEY (search_concept_id) REFERENCES public.search_concepts(id) ON DELETE CASCADE;


--
-- Name: sessions fk_rails_758836b4f0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT fk_rails_758836b4f0 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: reading_plan_progress fk_rails_76e0ab215b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reading_plan_progress
    ADD CONSTRAINT fk_rails_76e0ab215b FOREIGN KEY (reading_plan_entry_id) REFERENCES public.reading_plan_entries(id);


--
-- Name: alignment_groups fk_rails_76edf380d1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alignment_groups
    ADD CONSTRAINT fk_rails_76edf380d1 FOREIGN KEY (target_work_id) REFERENCES public.works(id);


--
-- Name: words fk_rails_78c95b87dc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.words
    ADD CONSTRAINT fk_rails_78c95b87dc FOREIGN KEY (lemma_id) REFERENCES public.lemmas(id);


--
-- Name: alignment_group_members fk_rails_7bf8f65f9e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alignment_group_members
    ADD CONSTRAINT fk_rails_7bf8f65f9e FOREIGN KEY (import_run_id) REFERENCES public.import_runs(id);


--
-- Name: canonical_works fk_rails_82eeff38ed; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.canonical_works
    ADD CONSTRAINT fk_rails_82eeff38ed FOREIGN KEY (versification_scheme_id) REFERENCES public.versification_schemes(id);


--
-- Name: words fk_rails_8cde9ac6a1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.words
    ADD CONSTRAINT fk_rails_8cde9ac6a1 FOREIGN KEY (work_unit_id) REFERENCES public.work_units(id);


--
-- Name: work_units fk_rails_8d49a1ae13; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_units
    ADD CONSTRAINT fk_rails_8d49a1ae13 FOREIGN KEY (import_run_id) REFERENCES public.import_runs(id);


--
-- Name: canonical_works fk_rails_8f9e476731; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.canonical_works
    ADD CONSTRAINT fk_rails_8f9e476731 FOREIGN KEY (parent_canonical_work_id) REFERENCES public.canonical_works(id);


--
-- Name: works fk_rails_90863a0e02; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.works
    ADD CONSTRAINT fk_rails_90863a0e02 FOREIGN KEY (license_id) REFERENCES public.licenses(id);


--
-- Name: work_unit_notes fk_rails_90e7c8c18a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_unit_notes
    ADD CONSTRAINT fk_rails_90e7c8c18a FOREIGN KEY (import_run_id) REFERENCES public.import_runs(id);


--
-- Name: cross_references fk_rails_9e728ac034; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cross_references
    ADD CONSTRAINT fk_rails_9e728ac034 FOREIGN KEY (import_run_id) REFERENCES public.import_runs(id);


--
-- Name: variant_units fk_rails_9e8d7f6e9d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.variant_units
    ADD CONSTRAINT fk_rails_9e8d7f6e9d FOREIGN KEY (base_reading_id) REFERENCES public.readings(id);


--
-- Name: participant_references fk_rails_9fca1b46d3; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.participant_references
    ADD CONSTRAINT fk_rails_9fca1b46d3 FOREIGN KEY (work_unit_id) REFERENCES public.work_units(id);


--
-- Name: reading_plan_progress fk_rails_a05cb52cb0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reading_plan_progress
    ADD CONSTRAINT fk_rails_a05cb52cb0 FOREIGN KEY (reading_plan_id) REFERENCES public.reading_plans(id);


--
-- Name: work_units fk_rails_a3112d08af; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_units
    ADD CONSTRAINT fk_rails_a3112d08af FOREIGN KEY (parent_id) REFERENCES public.work_units(id);


--
-- Name: readings fk_rails_a43b7944df; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.readings
    ADD CONSTRAINT fk_rails_a43b7944df FOREIGN KEY (import_run_id) REFERENCES public.import_runs(id);


--
-- Name: readings fk_rails_a56e170522; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.readings
    ADD CONSTRAINT fk_rails_a56e170522 FOREIGN KEY (variant_unit_id) REFERENCES public.variant_units(id);


--
-- Name: cross_references fk_rails_ac7e959e1f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cross_references
    ADD CONSTRAINT fk_rails_ac7e959e1f FOREIGN KEY (target_canonical_work_id) REFERENCES public.canonical_works(id);


--
-- Name: bookmarks fk_rails_b1e5de4419; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookmarks
    ADD CONSTRAINT fk_rails_b1e5de4419 FOREIGN KEY (canonical_ref_id) REFERENCES public.canonical_refs(id);


--
-- Name: personal_notes fk_rails_bbd960570a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_notes
    ADD CONSTRAINT fk_rails_bbd960570a FOREIGN KEY (canonical_work_id) REFERENCES public.canonical_works(id);


--
-- Name: words fk_rails_bc4c3ea09d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.words
    ADD CONSTRAINT fk_rails_bc4c3ea09d FOREIGN KEY (work_id) REFERENCES public.works(id);


--
-- Name: users fk_rails_bc76119071; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT fk_rails_bc76119071 FOREIGN KEY (invited_by_user_id) REFERENCES public.users(id);


--
-- Name: bookmarks fk_rails_c1ff6fa4ac; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookmarks
    ADD CONSTRAINT fk_rails_c1ff6fa4ac FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: cross_references fk_rails_c93e3b1cc8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cross_references
    ADD CONSTRAINT fk_rails_c93e3b1cc8 FOREIGN KEY (approved_by_user_id) REFERENCES public.users(id);


--
-- Name: work_unit_notes fk_rails_ca47e121e7; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_unit_notes
    ADD CONSTRAINT fk_rails_ca47e121e7 FOREIGN KEY (work_unit_id) REFERENCES public.work_units(id);


--
-- Name: syntax_nodes fk_rails_cae1e2287d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.syntax_nodes
    ADD CONSTRAINT fk_rails_cae1e2287d FOREIGN KEY (parent_id) REFERENCES public.syntax_nodes(id);


--
-- Name: personal_notes fk_rails_cc390de5f5; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.personal_notes
    ADD CONSTRAINT fk_rails_cc390de5f5 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: reading_witnesses fk_rails_cf4aa4587e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reading_witnesses
    ADD CONSTRAINT fk_rails_cf4aa4587e FOREIGN KEY (reading_id) REFERENCES public.readings(id);


--
-- Name: alignment_groups fk_rails_d4642f89d1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alignment_groups
    ADD CONSTRAINT fk_rails_d4642f89d1 FOREIGN KEY (import_run_id) REFERENCES public.import_runs(id);


--
-- Name: reading_plan_entries fk_rails_d614a2e248; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reading_plan_entries
    ADD CONSTRAINT fk_rails_d614a2e248 FOREIGN KEY (canonical_work_id) REFERENCES public.canonical_works(id);


--
-- Name: alignment_groups fk_rails_d92bc1b970; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alignment_groups
    ADD CONSTRAINT fk_rails_d92bc1b970 FOREIGN KEY (source_work_id) REFERENCES public.works(id);


--
-- Name: versification_mappings fk_rails_da88fc73b4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.versification_mappings
    ADD CONSTRAINT fk_rails_da88fc73b4 FOREIGN KEY (to_canonical_ref_id) REFERENCES public.canonical_refs(id);


--
-- Name: alignment_group_members fk_rails_db32304417; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alignment_group_members
    ADD CONSTRAINT fk_rails_db32304417 FOREIGN KEY (alignment_group_id) REFERENCES public.alignment_groups(id);


--
-- Name: variant_units fk_rails_dbd4583309; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.variant_units
    ADD CONSTRAINT fk_rails_dbd4583309 FOREIGN KEY (canonical_ref_id) REFERENCES public.canonical_refs(id);


--
-- Name: cross_references fk_rails_dbff1ec14b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cross_references
    ADD CONSTRAINT fk_rails_dbff1ec14b FOREIGN KEY (source_canonical_work_id) REFERENCES public.canonical_works(id);


--
-- Name: cross_references fk_rails_e01915d2dc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cross_references
    ADD CONSTRAINT fk_rails_e01915d2dc FOREIGN KEY (created_by_user_id) REFERENCES public.users(id);


--
-- Name: annotations fk_rails_e23c92fc93; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.annotations
    ADD CONSTRAINT fk_rails_e23c92fc93 FOREIGN KEY (reviewed_by_user_id) REFERENCES public.users(id);


--
-- Name: search_concept_verses fk_rails_e2d3be77ae; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.search_concept_verses
    ADD CONSTRAINT fk_rails_e2d3be77ae FOREIGN KEY (import_run_id) REFERENCES public.import_runs(id);


--
-- Name: canonical_refs fk_rails_e3025c9d71; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.canonical_refs
    ADD CONSTRAINT fk_rails_e3025c9d71 FOREIGN KEY (canonical_work_id) REFERENCES public.canonical_works(id);


--
-- Name: works fk_rails_e56e68c70b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.works
    ADD CONSTRAINT fk_rails_e56e68c70b FOREIGN KEY (import_run_id) REFERENCES public.import_runs(id);


--
-- Name: work_authorships fk_rails_f201a20e4e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_authorships
    ADD CONSTRAINT fk_rails_f201a20e4e FOREIGN KEY (work_id) REFERENCES public.works(id);


--
-- Name: syntax_nodes fk_rails_f4565f7ba8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.syntax_nodes
    ADD CONSTRAINT fk_rails_f4565f7ba8 FOREIGN KEY (work_id) REFERENCES public.works(id);


--
-- Name: canonical_refs fk_rails_f8656d1eaf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.canonical_refs
    ADD CONSTRAINT fk_rails_f8656d1eaf FOREIGN KEY (import_run_id) REFERENCES public.import_runs(id);


--
-- Name: participant_references fk_rails_fca994b121; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.participant_references
    ADD CONSTRAINT fk_rails_fca994b121 FOREIGN KEY (word_id) REFERENCES public.words(id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260427000000'),
('20260426230000'),
('20260426220000'),
('20260425200001'),
('20260425200000'),
('20260424165537'),
('20260424165505'),
('20260420120217'),
('20260420010725'),
('20260419220919'),
('20260419181228'),
('20260419174220'),
('20260419035929'),
('20260419033927'),
('20260419025713'),
('20260416010000'),
('20260413190532'),
('20260413044230'),
('20260413001603'),
('20260410224101'),
('20260410222738'),
('20260410025506'),
('20260409222131'),
('20260408060000'),
('20260408050007'),
('20260408050006'),
('20260408050005'),
('20260408050004'),
('20260408050003'),
('20260408050002'),
('20260408050001'),
('20260408050000'),
('20260408041526'),
('20260408041525'),
('20260408041524'),
('20260408041523'),
('20260408041522'),
('20260408041521'),
('20260408041520'),
('20260408041519'),
('20260408041518'),
('20260408041517'),
('20260408041516'),
('20260408041515'),
('20260408041514'),
('20260408041513'),
('20260408041512'),
('20260408041511'),
('20260408041510'),
('20260408041509'),
('20260408041508'),
('20260408041507'),
('20260408041506'),
('20260408041505'),
('20260408041504'),
('20260408041503'),
('20260408041502'),
('20260408041501'),
('20260408041500'),
('20260408041446'),
('20260408004335'),
('20260408004135'),
('20260408004133'),
('20260408004010');

