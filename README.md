# Open Scriptorium

An open reading room for scripture and the voices that have read it.

Open Scriptorium is a web application for browsing, comparing, and
cross-referencing freely licensed biblical texts and historical commentary.
It presents parallel translations of the Hebrew Bible, the Greek New
Testament, the Septuagint, and various apocryphal texts, alongside historical
commentary from Philo, Josephus, Origen, and later patristic and
post-patristic voices. Every text in the corpus is under a license that meets
the FSF definition of free software or the SIL Open Font License. The corpus
you read is the corpus you can fork.

The site is live at [openscriptorium.org](https://openscriptorium.org).
Source code is hosted on [sr.ht](https://git.sr.ht/~sethkush/openscriptorium).

## The corpus

Nine scripture works are currently loaded:

| Work | Language | Source |
|---|---|---|
| Westminster Leningrad Codex (WLC) | Hebrew | OpenScriptures / Groves Center |
| JPS 1917 Tanakh | English | Jewish Publication Society (public domain) |
| Nestle 1904 GNT | Greek | Diego Santos / biblicalhumanities.org |
| Robinson-Pierpont Byzantine Textform | Greek | byzantinetext.com |
| Rahlfs Septuagint (1935) | Greek | Eliran Wong / CCAT encoding |
| Brenton's English Septuagint (1851) | English | Public domain |
| Berean Standard Bible (BSB) | English | bereanbible.com (CC BY-SA 4.0) |
| King James Version with Apocrypha | English | Public domain |
| Lutherbibel 1912 | German | Public domain |

Cross-scheme alignment (LXX, MT, KJV, Vulgate, German) is handled by TVTMS
(Tyndale House Cambridge, CC BY 4.0).

In addition to the scripture texts:

- ~682,000 cross-references (from OpenBible.info CC BY 4.0 and Treasury of Scripture Knowledge CC BY-SA 4.0)
- ~3,000 pericopes (passage groupings)
- ~411,000 alignment groups (word-level Hebrew/Greek-to-English alignments from BSB interlinear tables)

Every verse aligns to a shared canonical reference, so any two works covering
the same passage can be read in parallel.

## Tech stack

| Layer | Choice |
|---|---|
| Framework | Rails 8.1 |
| Language | Ruby 3.4 |
| Database | PostgreSQL 18 |
| Postgres extensions | `btree_gist`, `pg_trgm`, `ltree`, `unaccent` |
| Frontend | Hotwire (Turbo + Stimulus), server-rendered ERB |
| CSS | Tailwind v4 via `tailwindcss-rails` |
| Asset pipeline | Propshaft |
| Auth | Rails 8 native (`has_secure_password`) |
| Background jobs | SolidQueue (Postgres-backed, no Redis) |
| Cache | SolidCache |
| Search | Postgres full-text search + GIN indexes, via `pg_search` |
| Versioning | PaperTrail |
| Markdown | commonmarker (libcmark-gfm) |
| Tests | Minitest + Capybara |
| Deploy | Capistrano to a Toronto VPS |

Fonts are bundled SIL OFL typefaces only (Charis SIL, Ezra SIL, Galatia SIL),
self-hosted from `app/assets/fonts/`. No external CDNs, no SBL fonts.

## Development setup

### Prerequisites

- Ruby 3.4+
- PostgreSQL 18+ with the `btree_gist`, `pg_trgm`, `ltree`, and `unaccent` extensions available
- Node.js (for Tailwind CLI via `tailwindcss-rails`)

### Steps

```sh
# Clone the repository
git clone https://git.sr.ht/~sethkush/openscriptorium
cd openscriptorium

# Install gems into vendor/bundle (avoids system gem directory permission issues)
bundle config set --local path 'vendor/bundle'
bundle install

# Create and migrate the database
bin/rails db:create
bin/rails db:migrate

# Seed canonical works and licenses
bin/rails db:seed

# Run the dev server
bin/dev
```

The app will be available at `http://localhost:3000`.

### Importing texts

Texts are loaded through rake tasks that call importer service objects. Each
importer downloads its source data on first run (pass `DOWNLOAD=false` to skip
the download and use previously cached files in `tmp/`).

```sh
# Import scripture texts
bin/rails import:bsb              # Berean Standard Bible
bin/rails import:bsb_tables       # BSB interlinear (WLC Hebrew + Nestle 1904 Greek + alignments)
bin/rails import:rp               # Robinson-Pierpont Byzantine NT
bin/rails import:rahlfs           # Rahlfs Septuagint 1935
bin/rails import:brenton          # Brenton's English LXX
bin/rails import:kjva             # King James Version with Apocrypha
bin/rails import:jps1917          # JPS 1917 Tanakh
bin/rails import:luther1912       # Lutherbibel 1912

# Import cross-references and versification mappings
bin/rails import:tvtms            # TVTMS versification mappings (LXX/MT/Vulgate <> KJV)
bin/rails import:openbible_xrefs  # OpenBible.info cross-references (~344k)
bin/rails import:tsk              # Treasury of Scripture Knowledge cross-references (~305k)
```

A recommended import order: `bsb`, then `bsb_tables` (which creates the WLC
and Nestle 1904 works plus word-level data), then `tvtms`, then the remaining
scripture texts, then cross-references.

## The import pipeline

All importers live in `app/services/importers/` and inherit from
`Importers::BaseImporter`. The base class enforces several conventions:

- **Idempotent.** Re-running an importer over an unchanged source produces
  zero database diffs.
- **Resumable.** Partial runs can pick up where they left off.
- **Provenance-tracked.** Every import creates a row in the `import_runs`
  table (recording the importer class, source URL, source format, timing, and
  stats). Every database row created by an importer is stamped with that run's
  `import_run_id`. Combined with PaperTrail versioning, this gives full
  provenance for academic reproducibility.
- **Transactional by default.** Importers run inside a single database
  transaction unless they override `transactional?` for incremental commits.

To write a new importer: subclass `Importers::BaseImporter`, implement
`#perform`, and use `stamp(record)` before saving to attach the import run.
Add a corresponding rake task in `lib/tasks/import.rake`.

## License

The source code of Open Scriptorium is free software. See the repository for
license details.

Each imported text carries its own license, tracked in the `works` table via a
`license_id` foreign key. Every passage view on the site displays provenance
and license attribution. The corpus includes public domain texts, CC BY works,
CC BY-SA works, and other licenses that meet the FSF definition of free
software. No text with a non-commercial, no-derivatives, or proprietary
license is accepted into the corpus.

## Further reading

- [Principles](https://openscriptorium.org/principles): what this project commits to and what it refuses.
- [An Appeal to Scholars](https://openscriptorium.org/appeal-to-scholars): asking editors and lexicographers to release their work under free licenses.
- [Architecture](https://openscriptorium.org/architecture): the unified addressing model, versification handling, and schema design.
- [TVTMS](https://github.com/STEPBible/STEPBible-Data/tree/master/Versification): the versification cross-walk from Tyndale House Cambridge.
- [OpenScriptures Hebrew Bible](https://hb.openscriptures.org/): the WLC source.
- [Nestle 1904 GNT](https://github.com/biblicalhumanities/Nestle1904): the Greek NT source.
- [Robinson-Pierpont Byzantine Textform](https://byzantinetext.com/): the Byzantine NT source.
