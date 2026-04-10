# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_04_10_222738) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "btree_gist"
  enable_extension "ltree"
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"
  enable_extension "unaccent"

  create_table "alignment_group_members", force: :cascade do |t|
    t.bigint "alignment_group_id", null: false
    t.datetime "created_at", null: false
    t.bigint "import_run_id"
    t.integer "position"
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.bigint "word_id", null: false
    t.index ["alignment_group_id", "role", "position"], name: "idx_align_members_grouping"
    t.index ["alignment_group_id"], name: "index_alignment_group_members_on_alignment_group_id"
    t.index ["import_run_id"], name: "index_alignment_group_members_on_import_run_id"
    t.index ["word_id"], name: "idx_align_members_word"
    t.index ["word_id"], name: "index_alignment_group_members_on_word_id"
  end

  create_table "alignment_groups", force: :cascade do |t|
    t.string "alignment_type", default: "literal", null: false
    t.bigint "canonical_ref_id", null: false
    t.decimal "confidence", precision: 4, scale: 3
    t.datetime "created_at", null: false
    t.bigint "import_run_id"
    t.bigint "source_work_id", null: false
    t.bigint "target_work_id", null: false
    t.datetime "updated_at", null: false
    t.index ["canonical_ref_id", "source_work_id", "target_work_id"], name: "idx_align_groups_lookup"
    t.index ["canonical_ref_id"], name: "index_alignment_groups_on_canonical_ref_id"
    t.index ["import_run_id"], name: "index_alignment_groups_on_import_run_id"
    t.index ["source_work_id"], name: "index_alignment_groups_on_source_work_id"
    t.index ["target_work_id"], name: "index_alignment_groups_on_target_work_id"
  end

  create_table "annotations", force: :cascade do |t|
    t.text "body_html"
    t.text "body_markdown", null: false
    t.int4range "canonical_range", null: false
    t.bigint "canonical_work_id", null: false
    t.datetime "created_at", null: false
    t.text "review_notes"
    t.datetime "reviewed_at"
    t.bigint "reviewed_by_user_id"
    t.string "status", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.string "visibility", default: "private", null: false
    t.index ["canonical_work_id", "canonical_range"], name: "idx_annotations_range", using: :gist
    t.index ["canonical_work_id"], name: "index_annotations_on_canonical_work_id"
    t.index ["reviewed_by_user_id"], name: "index_annotations_on_reviewed_by_user_id"
    t.index ["status"], name: "index_annotations_on_status"
    t.index ["user_id", "status"], name: "index_annotations_on_user_id_and_status"
    t.index ["user_id"], name: "index_annotations_on_user_id"
  end

  create_table "authors", force: :cascade do |t|
    t.text "bio"
    t.integer "birth_year"
    t.datetime "created_at", null: false
    t.integer "death_year"
    t.string "era"
    t.string "latin_name"
    t.string "name", null: false
    t.string "native_name"
    t.string "slug", null: false
    t.string "sort_name"
    t.string "tradition"
    t.datetime "updated_at", null: false
    t.string "wikipedia_url"
    t.index ["slug"], name: "index_authors_on_slug", unique: true
    t.index ["sort_name"], name: "index_authors_on_sort_name"
    t.index ["tradition"], name: "index_authors_on_tradition"
  end

  create_table "bookmarks", force: :cascade do |t|
    t.bigint "canonical_ref_id", null: false
    t.bigint "canonical_work_id", null: false
    t.datetime "created_at", null: false
    t.string "label"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["canonical_ref_id"], name: "index_bookmarks_on_canonical_ref_id"
    t.index ["canonical_work_id"], name: "index_bookmarks_on_canonical_work_id"
    t.index ["user_id", "canonical_ref_id"], name: "index_bookmarks_on_user_id_and_canonical_ref_id", unique: true
    t.index ["user_id"], name: "index_bookmarks_on_user_id"
  end

  create_table "canonical_refs", force: :cascade do |t|
    t.bigint "canonical_work_id", null: false
    t.datetime "created_at", null: false
    t.string "display_label", null: false
    t.integer "hierarchy", default: [], null: false, array: true
    t.bigint "import_run_id"
    t.integer "ord", null: false
    t.string "osis_id"
    t.string "sbl_citation"
    t.datetime "updated_at", null: false
    t.index ["canonical_work_id", "ord"], name: "index_canonical_refs_on_canonical_work_id_and_ord", unique: true
    t.index ["canonical_work_id"], name: "index_canonical_refs_on_canonical_work_id"
    t.index ["hierarchy"], name: "index_canonical_refs_on_hierarchy", using: :gin
    t.index ["import_run_id"], name: "index_canonical_refs_on_import_run_id"
    t.index ["osis_id"], name: "index_canonical_refs_on_osis_id"
    t.index ["sbl_citation"], name: "index_canonical_refs_on_sbl_citation"
  end

  create_table "canonical_works", force: :cascade do |t|
    t.string "book_key", null: false
    t.string "citation_format", default: "scripture"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "native_title"
    t.string "osis_book_id"
    t.bigint "parent_canonical_work_id"
    t.integer "position"
    t.string "sbl_abbreviation"
    t.string "slug", null: false
    t.string "testament"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "versification_scheme_id"
    t.index ["book_key"], name: "index_canonical_works_on_book_key"
    t.index ["osis_book_id"], name: "index_canonical_works_on_osis_book_id"
    t.index ["parent_canonical_work_id", "position"], name: "index_canonical_works_on_parent_canonical_work_id_and_position"
    t.index ["parent_canonical_work_id"], name: "index_canonical_works_on_parent_canonical_work_id"
    t.index ["slug"], name: "index_canonical_works_on_slug", unique: true
    t.index ["testament"], name: "index_canonical_works_on_testament"
    t.index ["versification_scheme_id"], name: "index_canonical_works_on_versification_scheme_id"
  end

  create_table "cross_references", force: :cascade do |t|
    t.datetime "approved_at"
    t.bigint "approved_by_user_id"
    t.decimal "confidence", precision: 4, scale: 3
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id"
    t.bigint "import_run_id"
    t.text "notes"
    t.string "relationship_type", null: false
    t.bigint "source_canonical_work_id", null: false
    t.string "source_dataset"
    t.int4range "source_range", null: false
    t.string "status", default: "approved", null: false
    t.bigint "target_canonical_work_id", null: false
    t.int4range "target_range", null: false
    t.datetime "updated_at", null: false
    t.index ["approved_by_user_id"], name: "index_cross_references_on_approved_by_user_id"
    t.index ["created_by_user_id"], name: "index_cross_references_on_created_by_user_id"
    t.index ["import_run_id"], name: "index_cross_references_on_import_run_id"
    t.index ["source_canonical_work_id", "source_range"], name: "idx_xrefs_source_range", using: :gist
    t.index ["source_canonical_work_id"], name: "index_cross_references_on_source_canonical_work_id"
    t.index ["source_dataset"], name: "index_cross_references_on_source_dataset"
    t.index ["status"], name: "index_cross_references_on_status"
    t.index ["target_canonical_work_id", "target_range"], name: "idx_xrefs_target_range", using: :gist
    t.index ["target_canonical_work_id"], name: "index_cross_references_on_target_canonical_work_id"
  end

  create_table "import_runs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error_backtrace"
    t.text "error_message"
    t.datetime "finished_at"
    t.string "importer_class", null: false
    t.jsonb "options", default: {}, null: false
    t.bigint "source_byte_count"
    t.string "source_format"
    t.string "source_revision"
    t.string "source_url"
    t.datetime "started_at", null: false
    t.jsonb "stats", default: {}, null: false
    t.string "status", default: "running", null: false
    t.datetime "updated_at", null: false
    t.index ["importer_class"], name: "index_import_runs_on_importer_class"
    t.index ["started_at"], name: "index_import_runs_on_started_at"
    t.index ["status"], name: "index_import_runs_on_status"
  end

  create_table "invitations", force: :cascade do |t|
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.datetime "expires_at"
    t.text "notes"
    t.datetime "updated_at", null: false
    t.datetime "used_at"
    t.bigint "used_by_user_id"
    t.index ["code"], name: "index_invitations_on_code", unique: true
    t.index ["created_by_user_id"], name: "index_invitations_on_created_by_user_id"
    t.index ["used_at"], name: "index_invitations_on_used_at"
    t.index ["used_by_user_id"], name: "index_invitations_on_used_by_user_id"
  end

  create_table "lemmas", force: :cascade do |t|
    t.string "attested_period"
    t.datetime "created_at", null: false
    t.text "etymology"
    t.integer "frequency", default: 0, null: false
    t.jsonb "frequency_by_book", default: {}, null: false
    t.bigint "import_run_id"
    t.string "language", null: false
    t.string "lemma", null: false
    t.bigint "lexicon_entry_id"
    t.string "normalized", null: false
    t.string "part_of_speech"
    t.string "primary_gloss"
    t.integer "related_lemma_ids", default: [], null: false, array: true
    t.jsonb "senses", default: [], null: false
    t.string "transliteration"
    t.datetime "updated_at", null: false
    t.index ["import_run_id"], name: "index_lemmas_on_import_run_id"
    t.index ["language", "lemma"], name: "index_lemmas_on_language_and_lemma", unique: true
    t.index ["language", "normalized"], name: "index_lemmas_on_language_and_normalized"
    t.index ["lexicon_entry_id"], name: "index_lemmas_on_lexicon_entry_id"
    t.index ["related_lemma_ids"], name: "index_lemmas_on_related_lemma_ids", using: :gin
  end

  create_table "licenses", force: :cascade do |t|
    t.boolean "attribution_required", default: false, null: false
    t.string "attribution_template"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.string "spdx_id"
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["name"], name: "index_licenses_on_name", unique: true
    t.index ["spdx_id"], name: "index_licenses_on_spdx_id", unique: true
  end

  create_table "manuscripts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "date_text"
    t.integer "date_year_estimate"
    t.text "description"
    t.text "extent_description"
    t.string "family"
    t.string "format"
    t.string "gregory_aland_number"
    t.string "image_url"
    t.bigint "import_run_id"
    t.string "intf_liste_number"
    t.jsonb "lacunae", default: [], null: false
    t.string "language"
    t.string "location"
    t.string "material"
    t.string "name"
    t.string "shelfmark"
    t.string "siglum", null: false
    t.datetime "updated_at", null: false
    t.index ["family"], name: "index_manuscripts_on_family"
    t.index ["gregory_aland_number"], name: "index_manuscripts_on_gregory_aland_number"
    t.index ["import_run_id"], name: "index_manuscripts_on_import_run_id"
    t.index ["intf_liste_number"], name: "index_manuscripts_on_intf_liste_number"
    t.index ["siglum"], name: "index_manuscripts_on_siglum", unique: true
  end

  create_table "pericopes", force: :cascade do |t|
    t.int4range "canonical_range", null: false
    t.bigint "canonical_work_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.bigint "import_run_id"
    t.string "name", null: false
    t.string "native_name"
    t.string "pericope_type"
    t.integer "sequence_number"
    t.string "source_dataset", null: false
    t.string "tradition"
    t.datetime "updated_at", null: false
    t.index ["canonical_work_id", "canonical_range"], name: "idx_pericopes_range", using: :gist
    t.index ["canonical_work_id"], name: "index_pericopes_on_canonical_work_id"
    t.index ["import_run_id"], name: "index_pericopes_on_import_run_id"
    t.index ["pericope_type"], name: "index_pericopes_on_pericope_type"
    t.index ["source_dataset", "sequence_number"], name: "index_pericopes_on_source_dataset_and_sequence_number"
    t.index ["source_dataset"], name: "index_pericopes_on_source_dataset"
    t.index ["tradition"], name: "index_pericopes_on_tradition"
  end

  create_table "personal_notes", force: :cascade do |t|
    t.text "body_html"
    t.text "body_markdown", null: false
    t.int4range "canonical_range", null: false
    t.bigint "canonical_work_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["canonical_work_id"], name: "index_personal_notes_on_canonical_work_id"
    t.index ["user_id", "canonical_work_id", "canonical_range"], name: "idx_personal_notes_range", using: :gist
    t.index ["user_id"], name: "index_personal_notes_on_user_id"
  end

  create_table "reading_plan_entries", force: :cascade do |t|
    t.int4range "canonical_range", null: false
    t.bigint "canonical_work_id", null: false
    t.datetime "created_at", null: false
    t.integer "day", null: false
    t.string "label"
    t.integer "position", default: 0, null: false
    t.bigint "reading_plan_id", null: false
    t.datetime "updated_at", null: false
    t.index ["canonical_work_id"], name: "index_reading_plan_entries_on_canonical_work_id"
    t.index ["reading_plan_id", "day", "position"], name: "idx_rp_entries_order", unique: true
    t.index ["reading_plan_id"], name: "index_reading_plan_entries_on_reading_plan_id"
  end

  create_table "reading_plan_progress", force: :cascade do |t|
    t.datetime "completed_at", null: false
    t.datetime "created_at", null: false
    t.bigint "reading_plan_entry_id", null: false
    t.bigint "reading_plan_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["reading_plan_entry_id"], name: "index_reading_plan_progress_on_reading_plan_entry_id"
    t.index ["reading_plan_id"], name: "index_reading_plan_progress_on_reading_plan_id"
    t.index ["user_id", "reading_plan_entry_id"], name: "idx_rp_progress_unique", unique: true
    t.index ["user_id"], name: "index_reading_plan_progress_on_user_id"
  end

  create_table "reading_plans", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "created_by_user_id", null: false
    t.text "description"
    t.boolean "is_public", default: false, null: false
    t.integer "length_days"
    t.string "slug", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_user_id"], name: "index_reading_plans_on_created_by_user_id"
    t.index ["is_public"], name: "index_reading_plans_on_is_public"
    t.index ["slug"], name: "index_reading_plans_on_slug", unique: true
  end

  create_table "reading_witnesses", force: :cascade do |t|
    t.string "certainty"
    t.integer "column_number"
    t.string "correction_layer"
    t.datetime "created_at", null: false
    t.string "folio"
    t.bigint "import_run_id"
    t.boolean "is_lacuna", default: false, null: false
    t.boolean "is_supplement", default: false, null: false
    t.integer "line_number"
    t.bigint "manuscript_id", null: false
    t.text "notes"
    t.bigint "reading_id", null: false
    t.datetime "updated_at", null: false
    t.index ["import_run_id"], name: "index_reading_witnesses_on_import_run_id"
    t.index ["manuscript_id"], name: "index_reading_witnesses_on_manuscript_id"
    t.index ["reading_id", "manuscript_id"], name: "index_reading_witnesses_on_reading_id_and_manuscript_id", unique: true
    t.index ["reading_id"], name: "index_reading_witnesses_on_reading_id"
  end

  create_table "readings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "import_run_id"
    t.boolean "is_base", default: false, null: false
    t.text "normalized_text"
    t.text "notes"
    t.text "text", null: false
    t.datetime "updated_at", null: false
    t.bigint "variant_unit_id", null: false
    t.index ["import_run_id"], name: "index_readings_on_import_run_id"
    t.index ["variant_unit_id", "is_base"], name: "index_readings_on_variant_unit_id_and_is_base"
    t.index ["variant_unit_id"], name: "index_readings_on_variant_unit_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.text "value"
    t.index ["key"], name: "index_settings_on_key", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.text "bio"
    t.datetime "created_at", null: false
    t.string "display_name"
    t.string "email_address", null: false
    t.datetime "email_confirmed_at"
    t.datetime "invited_at"
    t.bigint "invited_by_user_id"
    t.string "password_digest", null: false
    t.jsonb "preferences", default: {}, null: false
    t.string "role", default: "visitor", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
    t.index ["invited_by_user_id"], name: "index_users_on_invited_by_user_id"
    t.index ["role"], name: "index_users_on_role"
  end

  create_table "variant_units", force: :cascade do |t|
    t.bigint "base_reading_id"
    t.bigint "canonical_ref_id", null: false
    t.text "context_after"
    t.text "context_before"
    t.datetime "created_at", null: false
    t.bigint "import_run_id"
    t.text "lemma_text"
    t.text "notes"
    t.integer "position_within_ref", default: 1, null: false
    t.datetime "updated_at", null: false
    t.string "variant_type"
    t.index ["base_reading_id"], name: "index_variant_units_on_base_reading_id"
    t.index ["canonical_ref_id", "position_within_ref"], name: "idx_on_canonical_ref_id_position_within_ref_374ea7e394", unique: true
    t.index ["canonical_ref_id"], name: "index_variant_units_on_canonical_ref_id"
    t.index ["import_run_id"], name: "index_variant_units_on_import_run_id"
  end

  create_table "versification_mappings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "from_canonical_ref_id", null: false
    t.bigint "from_scheme_id", null: false
    t.string "mapping_type", null: false
    t.text "notes"
    t.bigint "to_canonical_ref_id", null: false
    t.bigint "to_scheme_id", null: false
    t.datetime "updated_at", null: false
    t.index ["from_canonical_ref_id"], name: "index_versification_mappings_on_from_canonical_ref_id"
    t.index ["from_scheme_id", "from_canonical_ref_id", "to_scheme_id"], name: "idx_v11n_mappings_from"
    t.index ["from_scheme_id"], name: "index_versification_mappings_on_from_scheme_id"
    t.index ["to_canonical_ref_id"], name: "index_versification_mappings_on_to_canonical_ref_id"
    t.index ["to_scheme_id", "to_canonical_ref_id", "from_scheme_id"], name: "idx_v11n_mappings_to"
    t.index ["to_scheme_id"], name: "index_versification_mappings_on_to_scheme_id"
  end

  create_table "versification_schemes", force: :cascade do |t|
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "display_name", null: false
    t.string "source_url"
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_versification_schemes_on_code", unique: true
  end

  create_table "versions", force: :cascade do |t|
    t.datetime "created_at"
    t.string "event", null: false
    t.bigint "item_id", null: false
    t.string "item_type", null: false
    t.text "object"
    t.string "whodunnit"
    t.index ["item_type", "item_id"], name: "index_versions_on_item_type_and_item_id"
  end

  create_table "words", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "import_run_id"
    t.bigint "lemma_id"
    t.string "morph_code"
    t.string "normalized"
    t.jsonb "notes", default: {}, null: false
    t.integer "position", null: false
    t.string "strongs_number"
    t.string "surface", null: false
    t.datetime "updated_at", null: false
    t.bigint "work_id", null: false
    t.bigint "work_unit_id", null: false
    t.index ["import_run_id"], name: "index_words_on_import_run_id"
    t.index ["lemma_id"], name: "index_words_on_lemma_id"
    t.index ["strongs_number"], name: "index_words_on_strongs_number"
    t.index ["work_id"], name: "index_words_on_work_id"
    t.index ["work_unit_id", "position"], name: "index_words_on_work_unit_id_and_position"
    t.index ["work_unit_id"], name: "index_words_on_work_unit_id"
  end

  create_table "work_authorships", force: :cascade do |t|
    t.bigint "author_id", null: false
    t.datetime "created_at", null: false
    t.integer "position"
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.bigint "work_id", null: false
    t.index ["author_id"], name: "index_work_authorships_on_author_id"
    t.index ["work_id", "author_id", "role"], name: "index_work_authorships_on_work_id_and_author_id_and_role", unique: true
    t.index ["work_id"], name: "index_work_authorships_on_work_id"
  end

  create_table "work_unit_notes", force: :cascade do |t|
    t.text "anchor_text"
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.bigint "import_run_id"
    t.string "note_type", null: false
    t.integer "position_in_unit", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "work_unit_id", null: false
    t.index ["import_run_id"], name: "index_work_unit_notes_on_import_run_id"
    t.index ["note_type"], name: "index_work_unit_notes_on_note_type"
    t.index ["work_unit_id", "position_in_unit"], name: "index_work_unit_notes_on_work_unit_id_and_position_in_unit"
    t.index ["work_unit_id"], name: "index_work_unit_notes_on_work_unit_id"
  end

  create_table "work_units", force: :cascade do |t|
    t.text "body"
    t.decimal "canonical_alignment_confidence", precision: 4, scale: 3
    t.string "canonical_alignment_type", default: "exact"
    t.bigint "canonical_ref_id"
    t.datetime "created_at", null: false
    t.ltree "hierarchy_path"
    t.bigint "import_run_id"
    t.string "label"
    t.jsonb "markup", default: {}, null: false
    t.integer "ord", null: false
    t.bigint "parent_id"
    t.integer "position"
    t.datetime "updated_at", null: false
    t.bigint "work_id", null: false
    t.index ["canonical_ref_id"], name: "index_work_units_on_canonical_ref_id"
    t.index ["hierarchy_path"], name: "index_work_units_on_hierarchy_path", using: :gist
    t.index ["import_run_id"], name: "index_work_units_on_import_run_id"
    t.index ["parent_id", "position"], name: "index_work_units_on_parent_id_and_position"
    t.index ["parent_id"], name: "index_work_units_on_parent_id"
    t.index ["work_id", "ord"], name: "index_work_units_on_work_id_and_ord", unique: true
    t.index ["work_id"], name: "index_work_units_on_work_id"
  end

  create_table "works", force: :cascade do |t|
    t.string "cached_feature_flags", default: [], array: true
    t.datetime "created_at", null: false
    t.bigint "default_versification_scheme_id"
    t.text "description"
    t.string "era"
    t.string "genre"
    t.boolean "has_apparatus", default: false, null: false
    t.boolean "has_word_data", default: false, null: false
    t.text "import_notes"
    t.bigint "import_run_id"
    t.datetime "imported_at"
    t.string "language"
    t.datetime "last_imported_at"
    t.bigint "license_id", null: false
    t.string "native_title"
    t.string "pericope_traditions", default: [], array: true
    t.integer "publication_year"
    t.string "slug", null: false
    t.string "source_revision"
    t.string "source_url"
    t.string "title", null: false
    t.string "traditions", default: [], array: true
    t.datetime "updated_at", null: false
    t.string "work_type", null: false
    t.index ["default_versification_scheme_id"], name: "index_works_on_default_versification_scheme_id"
    t.index ["import_run_id"], name: "index_works_on_import_run_id"
    t.index ["language"], name: "index_works_on_language"
    t.index ["license_id"], name: "index_works_on_license_id"
    t.index ["pericope_traditions"], name: "index_works_on_pericope_traditions", using: :gin
    t.index ["slug"], name: "index_works_on_slug", unique: true
    t.index ["traditions"], name: "index_works_on_traditions", using: :gin
    t.index ["work_type"], name: "index_works_on_work_type"
  end

  add_foreign_key "alignment_group_members", "alignment_groups"
  add_foreign_key "alignment_group_members", "import_runs"
  add_foreign_key "alignment_group_members", "words"
  add_foreign_key "alignment_groups", "canonical_refs"
  add_foreign_key "alignment_groups", "import_runs"
  add_foreign_key "alignment_groups", "works", column: "source_work_id"
  add_foreign_key "alignment_groups", "works", column: "target_work_id"
  add_foreign_key "annotations", "canonical_works"
  add_foreign_key "annotations", "users"
  add_foreign_key "annotations", "users", column: "reviewed_by_user_id"
  add_foreign_key "bookmarks", "canonical_refs"
  add_foreign_key "bookmarks", "canonical_works"
  add_foreign_key "bookmarks", "users"
  add_foreign_key "canonical_refs", "canonical_works"
  add_foreign_key "canonical_refs", "import_runs"
  add_foreign_key "canonical_works", "canonical_works", column: "parent_canonical_work_id"
  add_foreign_key "canonical_works", "versification_schemes"
  add_foreign_key "cross_references", "canonical_works", column: "source_canonical_work_id"
  add_foreign_key "cross_references", "canonical_works", column: "target_canonical_work_id"
  add_foreign_key "cross_references", "import_runs"
  add_foreign_key "cross_references", "users", column: "approved_by_user_id"
  add_foreign_key "cross_references", "users", column: "created_by_user_id"
  add_foreign_key "invitations", "users", column: "created_by_user_id"
  add_foreign_key "invitations", "users", column: "used_by_user_id"
  add_foreign_key "lemmas", "import_runs"
  add_foreign_key "lemmas", "work_units", column: "lexicon_entry_id"
  add_foreign_key "manuscripts", "import_runs"
  add_foreign_key "pericopes", "canonical_works"
  add_foreign_key "pericopes", "import_runs"
  add_foreign_key "personal_notes", "canonical_works"
  add_foreign_key "personal_notes", "users"
  add_foreign_key "reading_plan_entries", "canonical_works"
  add_foreign_key "reading_plan_entries", "reading_plans"
  add_foreign_key "reading_plan_progress", "reading_plan_entries"
  add_foreign_key "reading_plan_progress", "reading_plans"
  add_foreign_key "reading_plan_progress", "users"
  add_foreign_key "reading_plans", "users", column: "created_by_user_id"
  add_foreign_key "reading_witnesses", "import_runs"
  add_foreign_key "reading_witnesses", "manuscripts"
  add_foreign_key "reading_witnesses", "readings"
  add_foreign_key "readings", "import_runs"
  add_foreign_key "readings", "variant_units"
  add_foreign_key "sessions", "users"
  add_foreign_key "users", "users", column: "invited_by_user_id"
  add_foreign_key "variant_units", "canonical_refs"
  add_foreign_key "variant_units", "import_runs"
  add_foreign_key "variant_units", "readings", column: "base_reading_id"
  add_foreign_key "versification_mappings", "canonical_refs", column: "from_canonical_ref_id"
  add_foreign_key "versification_mappings", "canonical_refs", column: "to_canonical_ref_id"
  add_foreign_key "versification_mappings", "versification_schemes", column: "from_scheme_id"
  add_foreign_key "versification_mappings", "versification_schemes", column: "to_scheme_id"
  add_foreign_key "words", "import_runs"
  add_foreign_key "words", "lemmas"
  add_foreign_key "words", "work_units"
  add_foreign_key "words", "works"
  add_foreign_key "work_authorships", "authors"
  add_foreign_key "work_authorships", "works"
  add_foreign_key "work_unit_notes", "import_runs"
  add_foreign_key "work_unit_notes", "work_units"
  add_foreign_key "work_units", "canonical_refs"
  add_foreign_key "work_units", "import_runs"
  add_foreign_key "work_units", "work_units", column: "parent_id"
  add_foreign_key "work_units", "works"
  add_foreign_key "works", "import_runs"
  add_foreign_key "works", "licenses"
  add_foreign_key "works", "versification_schemes", column: "default_versification_scheme_id"
end
