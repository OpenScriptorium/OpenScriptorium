<p align="center">
  <img src="https://raw.githubusercontent.com/OpenScriptorium/OpenScriptorium/master/app/assets/images/letters/dropcap-S.png" width="120" alt="Open Scriptorium">
</p>

# Open Scriptorium

An open reading room for scripture and the voices that have read it.

Open Scriptorium is a web application for browsing, comparing, and
cross-referencing freely licensed biblical texts and historical commentary.
Parallel translations of the Hebrew Bible, the Greek New Testament, the
Septuagint, and the deuterocanon. The Babylonian Talmud with Rashi and
Tosafot. Historical commentary from Philo, Josephus, Origen, and later
patristic and post-patristic voices. All freely licensed, all
cross-referenced down to the verse. The corpus you read is the corpus you
can fork.

The site is live at [openscriptorium.org](https://openscriptorium.org).
Source code is hosted on [GitHub](https://github.com/OpenScriptorium/OpenScriptorium).
Bug reports and feature requests: [issue tracker](https://github.com/OpenScriptorium/OpenScriptorium/issues).
Discussion: [GitHub Discussions](https://github.com/OpenScriptorium/OpenScriptorium/discussions).

## The corpus

Scripture in Hebrew, Greek, Latin, English, French, and German — multiple
editions per tradition, every verse aligned to the same canonical reference
for parallel reading. The Babylonian Talmud with Rashi and Tosafot,
addressed by the traditional daf system.

The full list of works, with languages, licenses, traditions, and feature
flags, is at [openscriptorium.org/works](https://openscriptorium.org/works).

### Scripture

| Work | Language | License |
|---|---|---|
| Westminster Leningrad Codex (WLC) | Hebrew | Public domain |
| JPS 1917 Tanakh | English | Public domain |
| Nestle 1904 GNT | Greek | Public domain |
| Robinson-Pierpont Byzantine Textform | Greek | Public domain |
| CNTR Statistical Restoration | Greek | CC BY 4.0 |
| 1904 Patriarchal Greek NT | Greek | Public domain |
| Rahlfs Septuagint (1935) | Greek | Public domain |
| Brenton's English Septuagint (1851) | English | Public domain |
| Berean Standard Bible (BSB) | English | Public domain |
| King James Version with Apocrypha | English | Public domain |
| World English Bible British Edition (WEBBE) | English | Public domain |
| Clementine Vulgate | Latin | Public domain |
| Crampon 1904 | French | Public domain |
| Louis Segond 1910 | French | Public domain |
| Lutherbibel 1912 | German | Public domain |

### Talmud and commentary

| Work | Language | License |
|---|---|---|
| Babylonian Talmud (Gemara) | Aramaic/Hebrew | Public domain |
| Rashi on Talmud | Hebrew | Public domain |
| Tosafot on Talmud | Hebrew | Public domain |

### Supplementary data

- **Cross-references**: ~682,000 links from OpenBible.info (CC BY 4.0),
  Treasury of Scripture Knowledge (CC BY-SA 4.0), BSB inline references,
  and Sefaria links (Talmud ↔ Tanakh)
- **Versification mappings**: cross-scheme alignment
  (LXX ↔ MT ↔ KJV ↔ German) from TVTMS (Tyndale House Cambridge, CC BY 4.0)
- **Word-level alignment**: ~411,000 alignment groups linking BSB English
  words to Hebrew/Greek source words, with Strong's numbers and lemmas
- **Critical apparatus**: variant readings for CNTR (CC BY-SA 4.0) and
  Nestle 1904 (public domain)
- **Morphology**: lemmas and parsing on Rahlfs LXX (from CATSS), Strong's
  numbers on KJV
- **Pericopes**: ~3,000 BSB section headings, WLC parashot/sedarim
- **Footnotes**: translator notes on BSB, JPS 1917, Brenton's LXX;
  Ketiv/Qere notes on WLC
- **Vilna margin commentaries**: Rashash, Maharsha, Gilyon HaShas, and
  others on the Talmud

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
git clone https://github.com/OpenScriptorium/OpenScriptorium.git
cd OpenScriptorium

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
# Scripture texts
bin/rails import:bsb              # Berean Standard Bible
bin/rails import:bsb_tables       # BSB interlinear (WLC Hebrew + Nestle 1904 Greek + alignments)
bin/rails import:rp               # Robinson-Pierpont Byzantine NT
bin/rails import:cntr_sr          # CNTR Statistical Restoration Greek NT
bin/rails import:patriarchal_nt   # 1904 Patriarchal Greek NT
bin/rails import:rahlfs           # Rahlfs Septuagint 1935
bin/rails import:brenton          # Brenton's English LXX
bin/rails import:kjva             # King James Version with Apocrypha
bin/rails import:jps1917          # JPS 1917 Tanakh
bin/rails import:webbe            # World English Bible British Edition
bin/rails import:vulgate          # Clementine Vulgate
bin/rails import:crampon          # Crampon 1904 French Bible
bin/rails import:segond           # Louis Segond 1910 French Bible
bin/rails import:luther1912       # Lutherbibel 1912

# Talmud and commentary
bin/rails import:bavli            # Babylonian Talmud (Gemara + Rashi + Tosafot)
bin/rails import:vilna_margins    # Vilna margin commentaries
bin/rails import:vilna_refs       # Ein Mishpat / Mesoret HaShas references

# Cross-references and versification
bin/rails import:tvtms            # TVTMS versification mappings (LXX/MT/Vulgate/German ↔ KJV)
bin/rails import:openbible_xrefs  # OpenBible.info cross-references (~344k)
bin/rails import:tsk              # Treasury of Scripture Knowledge cross-references (~305k)
bin/rails import:sefaria_links    # Sefaria links (Talmud ↔ Tanakh, Talmud ↔ Talmud)

# Supplementary data (run after the base text is imported)
bin/rails import:kjv_strongs      # Strong's numbers and lemmas on KJV
bin/rails import:rahlfs_morph     # Morphology and lemmas on Rahlfs LXX
bin/rails import:brenton_notes    # Brenton's translator footnotes
bin/rails import:oshb_features    # WLC Ketiv/Qere notes + parashot
bin/rails import:cntr_apparatus   # CNTR critical apparatus
bin/rails import:nestle_apparatus # Nestle 1904 critical apparatus
```

A recommended import order: `bsb`, then `bsb_tables` (which creates the WLC
and Nestle 1904 works plus word-level data), then `tvtms`, then the remaining
scripture texts, then cross-references and supplementary data.

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

The source code of Open Scriptorium is released under the
[ISC License](LICENSE).

Each imported text carries its own license, tracked in the `works` table via a
`license_id` foreign key. Every passage view on the site displays provenance
and license attribution. The corpus includes public domain texts, CC BY works,
CC BY-SA works, and other licenses that meet the FSF definition of free
software. No text with a non-commercial, no-derivatives, or proprietary
license is accepted into the corpus.

## Further reading

- [Principles](https://openscriptorium.org/principles): what this project commits to and what it refuses.
- [An Appeal to Scholars](https://openscriptorium.org/appeal-to-scholars): asking editors and lexicographers to release their work under free licenses.
- [An Appeal to Publishers](https://openscriptorium.org/appeal-to-publishers): asking Bible publishers to release their texts under free licenses.
- [Architecture](https://openscriptorium.org/architecture): the unified addressing model, versification handling, and schema design.
- [Downloads & API](https://openscriptorium.org/downloads): bulk downloads and REST API documentation.
- [TVTMS](https://github.com/STEPBible/STEPBible-Data/tree/master/Versification): the versification cross-walk from Tyndale House Cambridge.
- [OpenScriptures Hebrew Bible](https://hb.openscriptures.org/): the WLC source.
- [Nestle 1904 GNT](https://github.com/biblicalhumanities/Nestle1904): the Greek NT source.
- [Robinson-Pierpont Byzantine Textform](https://byzantinetext.com/): the Byzantine NT source.
