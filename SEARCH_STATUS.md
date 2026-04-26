# Search Engine Status & Next Steps

Generated from audit run on 2026-04-23.

## Current State

Overall pass rate: **69.3%** (1669/2410 queries)

Previous baseline: 67.3% (before any Tier 1/2 work)

### By file

| File | Pass | Total | Rate |
|---|---|---|---|
| edge_cases | 289 | 298 | 97.0% |
| exact_quotes | 273 | 333 | 82.0% |
| named_passages | 179 | 264 | 67.8% |
| natural_language | 84 | 218 | 38.5% |
| original_language | 230 | 256 | 89.8% |
| paraphrase_semantic | 319 | 548 | 58.2% |
| people_narratives | 94 | 225 | 41.8% |
| theological | 201 | 268 | 75.0% |

### Person categories (focus area)

| Category | Before | Now |
|---|---|---|
| person-topic | 5.0% (1/20) | 20.0% (4/20) |
| person-action | 7.4% (2/27) | 22.2% (6/27) |
| person-event | 28.9% (13/45) | 28.9% (13/45) |
| person-speech | 70.0% (7/10) | 70.0% (7/10) |
| person-prayer | 30.0% (3/10) | 30.0% (3/10) |
| person-name | 53.3% (8/15) | 53.3% (8/15) |

## What was done (Tiers 1 & 2)

### Tier 1: Search ranking fixes (commits aafe3be, 63ed4b9)

- Removed person-topic OR fallback from TextSearch that was drowning precise FTS results
- Added ILIKE fallback for all-stopword queries ("I AM THAT I AM")
- Fixed phrase bonus to use Unicode-aware regex and check synonym-expanded forms
- Deduplicated FTS results by citation string
- Filtered fuzzy alias matches by content-word overlap
- Scanned alias ranges for best-matching verse
- Pinned alias matches through pericope retrieval and semantic merge pipeline
- Skipped semantic search when FTS has strong phrase matches
- Added `search:audit` rake task (2,410 test queries across 8 files)

### Tier 2a: PersonTopicSearch (commits 6e84e06, 6fd21ea, 7c68451, 373ce80, 29f36f6)

- New search strategy for "What did Jesus say about X?" queries
- Uses Macula participant_references (217K records) to find verses where the named person is the grammatical subject or semantic agent
- Fixed critical bug in MaculaParticipantsImporter: Greek NT book numbers (40-66) were missing, causing all ~70K Greek referent_word_ids to be NULL
- Three-tier search: agent verses (10x) > nearby speech window ±100 ords (5x) > primary books (1x)
- Pericope-name boost: verses in pericopes matching the topic get 3x boost; verses in pericopes matching BOTH person AND topic get 6x
- Root-form expansion for topic words: "prayer" also searches "pray", "forgiveness" also searches "forgive"
- Conceptual fallback: injects verses from topic-matching pericopes even when they don't contain the topic keyword

### Tier 2b: KJV vocabulary expansion (commit 6e84e06)

- Added 150 new synonym pairs to bible_synonyms table (151 to 301 total)
- Covers archaic verb forms (spake/spoke, sware/swore), directional adverbs (hither/here, thither/there), social terms (brethren/brothers), KJV vocabulary (raiment/clothing, sepulchre/tomb, mammon/money, fornication/sexual immorality)

### Bug fixes (commit 63ed4b9)

- Strong's leading zeros: H0430 now normalised to H430
- xref traversal: CitationParser now picks canonical_work with actual cross-reference data
- Fuzzy alias ranking by content-word overlap count
- Strong's results sorted by canonical book order

## What the audit tests

Test queries live in `tmp/audit_v6/*.json` (8 files, ~2,410 queries). Each has:
- `query`: the search string
- `check`: validation — `top1`, `top3`, `top10`, `any`, `count_gt`, `no_crash`
- `expected`: the expected citation (e.g., "Gen 1:1")
- `category`: classification for reporting

Run with: `bundle exec rake search:audit VERBOSE=1`

For faster iteration on a specific file: `bundle exec rake search:audit FILE=exact_quotes LIMIT=100`

Keyword-only (no embeddings, ~3x faster): `bundle exec rake search:audit MODE=keyword`

## What still fails and why

### Person-topic (hardest category)

The remaining failures fall into patterns:

1. **Expected verse doesn't contain the topic keyword** — "on the cross" but Luke 23:34 says "Father, forgive them"; "at Pentecost" but Acts 2:38 says "Repent and be baptized". Needs concept mapping or better semantic search.

2. **Near-misses** — expected verse is in the results at position 11-24, just outside top 10. The right passage is found but the specific verse ranks below alternatives. Examples: Matt 6:9 (prayer), Matt 6:14 (forgiveness), 1 Sam 17:45 (Goliath).

3. **"God" queries too broad** — "What did God say to Abraham?" has thousands of agent-verses for God. Needs special handling to narrow by the second person.

4. **Scene-based queries** — "at Pentecost", "on the cross", "at the burning bush" describe a location/event, not the content of the speech. Would need scene detection → speech extraction.

### Paraphrase/semantic (58%)

These are topical queries like "passages about anxiety" or conceptual paraphrases. They need better semantic search (fine-tuned embeddings) or Tier 2c (topical query improvement via pericope expansion for non-question queries).

### Named passages (68%)

Alias system works well for exact names. Failures are mostly fuzzy matches that don't find the right alias, or range aliases returning the wrong verse within the range.

## Recommended next steps (Tier 3+)

### High impact

1. **Fix remaining person-topic near-misses**: Many expected verses are at positions 11-15. Tuning the scoring weights or increasing top-N could flip several. Low risk.

2. **Tier 2c: Topical query expansion**: Extend pericope retrieval to fire for "passages/verses about X" patterns (not just question queries). Currently only runs for question-word queries. Would help the 58% paraphrase_semantic category.

3. **Greek lemma remapping**: ~13K Nestle 1904 words point to BSB-created inflected-form lemma records (wrong Hebrew lemmas). Match by Strong's number to proper STEP dictionary lemmas. Would improve lemma search, cross-language sidebar, and syntax search.

### Medium impact

4. **Fine-tune embeddings**: LaBSE is cross-lingual but mediocre for biblical synonymy. Training on KJV↔BSB verse pairs and cross-reference pairs would dramatically improve semantic search for paraphrase queries.

5. **Scene-based query detection**: For "What did X say at/on/during Y", detect Y as a scene keyword, find the scene via pericope/keyword, then extract the person's speech within that scene.

6. **Concept synonym layer**: Map abstract concepts to biblical vocabulary — "cross" → crucifixion/Golgotha/Calvary, "end times" → eschatology/last days/coming of the Son of Man, "messiah" → anointed/christ.

### Lower impact

7. **Audit expectation cleanup**: Several "failures" are debatable — parallel passages (Deut 5:7 vs Exod 20:3), same-passage near-misses (Matt 19:9 vs 19:6). Relaxing some expectations or accepting ±3 verse tolerance would better reflect actual search quality.

8. **Result grouping**: Show multiple translations as expandable sub-results instead of consuming separate top-N slots.

9. **Did-you-mean / autocomplete**: No suggestion engine exists yet.

## Key files

| File | Purpose |
|---|---|
| `app/services/search/executor.rb` | Main dispatcher, person-topic detection, post-processing pipeline |
| `app/services/search/strategies/text_search.rb` | FTS with phrase bonus, dedup, ILIKE fallback |
| `app/services/search/strategies/person_topic_search.rb` | Macula-powered person+topic search |
| `app/services/search/strategies/semantic_merge.rb` | Hybrid FTS+embedding merge with adaptive weights |
| `app/services/search/strategies/pericope_retrieval.rb` | Pericope-based result injection |
| `app/services/search/strategies/cross_language_search.rb` | Hebrew/Greek sidebar via lemma glosses |
| `app/services/search/query_classifier.rb` | Query type detection |
| `app/services/search/citation_parser.rb` | Citation string → canonical_ref resolution |
| `app/services/importers/macula_participants_importer.rb` | Imports Macula participant references |
| `lib/tasks/search_audit.rake` | Audit runner |
| `tmp/audit_v6/*.json` | Test query data (gitignored) |

## Database notes

- `bible_synonyms` table has 301 KJV↔modern English pairs — data only, no migration
- `participant_references` was re-imported with fixed Greek book numbers — 217K records, only 9 NULL referent_word_ids remaining
- The `.ruby-version` was updated from 3.4.8 to 3.4.9 locally on the Mac — commit this if desired

---

## 2026-04-25 — Embedding model race + retrieval-quality roadmap

### Held-out thematic eval

New eval: `lib/tasks/eval.rake :thematic`. Uses `search_concepts` (355 concepts × 2585 query variants = name + each alias) as queries; relevant docs = canonical_refs in `search_concept_verses`. Reports MRR@10, Recall@10, NDCG@10 — overall and per `kind`. Held out from any embedding training. The metric we should be optimizing for going forward.

JSONL output per run lives at `tmp/eval/thematic_<slug>_<ts>.jsonl`.

### Zero-shot model race results (FOSS-strict shortlist)

Three-way comparison, name-only MRR@10:

| kind | n | LaBSE (FT) | BGE-M3 (zs) | **Qwen3 (zs)** | Qwen3 vs LaBSE | Qwen3 vs BGE |
|---|---|---|---|---|---|---|
| attribute | 6 | 0.1875 | 0.1944 | **0.4405** | +25.3 pp | +24.6 pp |
| character | 14 | 0.1786 | 0.6905 | **0.7560** | +57.7 pp | +6.6 pp |
| event | 156 | 0.0414 | 0.1804 | **0.2602** | +21.9 pp | +8.0 pp |
| parable | 20 | 0.0667 | 0.1894 | **0.3892** | +32.3 pp | +20.0 pp |
| place | 44 | 0.0424 | 0.3008 | **0.3917** | +34.9 pp | +9.1 pp |
| title | 27 | 0.3827 | 0.4541 | **0.5763** | +19.4 pp | +12.2 pp |
| topic | 88 | 0.2043 | 0.3688 | **0.4562** | +25.2 pp | +8.7 pp |
| **ALL** | **355** | **0.1171** | **0.2837** | **0.3790** | **+26.2 pp** | **+9.5 pp** |

Best-of-variants ALL: LaBSE 0.2733 → BGE 0.6432 → Qwen3 **0.7618**. Recall@10 (best): 0.15 → 0.32 → **0.40**. NDCG@10 (best): 0.15 → 0.34 → **0.43**.

Categories that were hopeless on LaBSE (event/place/parable, MRR ~0.04–0.07) jumped to 0.26–0.39 with Qwen3. The fine-tune on alignment-pair data did not teach the semantic reasoning these queries need; Qwen3's pretraining did. BGE-M3 also dramatically beats fine-tuned LaBSE (+16.7 pp) — confirming that 2024+ multilingual encoders generally crush 2020 LaBSE on thematic tasks — but Qwen3 wins every category over BGE by 6.6–24.6 pp.

**Decision: Qwen3-Embedding-0.6B as bi-encoder.** Wins every category; margin over LaBSE is ~3.2× on overall MRR; margin over BGE is ~9.5 pp. No fine-tuning required to beat current production.

Run any candidate against the eval:

```bash
EMB_TABLE=work_unit_embeddings_qwen3_06b EMB_COLUMN=embedding \
  MODEL_PATH=Qwen/Qwen3-Embedding-0.6B QUERY_PROMPT=query \
  SLUG=qwen3_06b bin/rails eval:thematic
```

### Production stack (search intelligence as priority 1)

| Layer | Choice | Rationale |
|---|---|---|
| Bi-encoder retrieval | Qwen3-Embedding-0.6B, full 1024-dim | Race winner; Apache 2.0; fits 4 GB / 2 vCPU VPS |
| Hybrid recall | RRF(Qwen3 dense, pg_search FTS) | Catches literal-overlap queries (`title`/`topic`) the dense path can miss |
| Cross-encoder rerank | Qwen3-Reranker-0.6B, top-50 → top-10 | Same family as embedder; Apache 2.0; biggest single quality lever after bi-encoder swap |
| Latency mitigation | Hotwire progressive UX | Bi-encoder result paints in ~200 ms; reranker streams in via Turbo Stream + SolidQueue at ~1–1.5 s |

We do not Matryoshka-truncate Qwen3 dim, do not reduce reranker top-N, do not fall back to a smaller reranker. Quality first; absorb the latency tax with progressive UX.

### Inference architecture (Capistrano deploy, no Docker)

**Decision: in-process Ruby ONNX inference via the `informers` gem (which wraps `onnxruntime` + `tokenizers` native gems), running inside a dedicated SolidQueue worker.**

No Docker, no separate inference service to maintain, no HTTP overhead. Pure Ruby ops surface, deployed via Capistrano like everything else.

**Why a dedicated SolidQueue worker (not Puma workers):**

Loading both the bi-encoder (Qwen3-Embedding-0.6B) and reranker (Qwen3-Reranker-0.6B) into every Puma worker would consume too much memory on the 4 GB / 2 vCPU VPS. With models in a single SolidQueue worker process, Puma stays small and the inference cost is paid once.

The progressive UX pattern already needs SolidQueue (Turbo Stream broadcast on rerank completion). Generalize: have it own all the inference. Architecture:

```
Puma (HTTP, small):
  request → enqueue SearchJob(query) → render skeleton

SolidQueue worker (holds ONNX models, ~700 MB int8 total):
  encode query (Qwen3-Embedding) → pgvector top-100
  → optional BM25 RRF fuse
  → broadcast Turbo Stream: bi-encoder results (~200 ms total)
  → rerank top-50 (Qwen3-Reranker)
  → broadcast Turbo Stream: reranked results (~1.5 s total)
```

**Memory math on 4 GB:**

| Component | RSS |
|---|---|
| 2 Puma workers × 350 MB (no models) | 700 MB |
| 1 SolidQueue inference worker (int8 embedder + reranker) | 700 MB |
| Postgres | ~1 GB |
| OS | ~500 MB |
| **Total** | **~2.9 GB** |

Leaves ~1 GB headroom for Postgres page cache (HNSW hot pages). Comfortable.

**int8 quantization of the ONNX models is required to fit.** fp32 doubles each model footprint and pushes total RSS over 4 GB. Quality cost is typically <2 pp MRR drop on retrieval tasks — acceptable. If parity testing shows int8 hurts more than 3 pp, fall back to fp16 (still half of fp32) or, last resort, fp32 with a single Puma worker.

**First concrete move (do this before committing to the architecture):**

1. Export both Qwen3-Embedding-0.6B and Qwen3-Reranker-0.6B to ONNX:
   ```
   optimum-cli export onnx --model Qwen/Qwen3-Embedding-0.6B vendor/models/qwen3_embed/
   optimum-cli export onnx --model Qwen/Qwen3-Reranker-0.6B vendor/models/qwen3_rerank/
   ```
2. Quantize to int8 via `optimum-cli onnxruntime quantize --avx512`.
3. Parity check against the Python reference: encode 100 sample queries with each ONNX variant + Python sentence-transformers; cosine similarity to reference should be >0.999 for fp32, >0.99 for int8. If int8 fails parity, downgrade to fp16.
4. Wire `informers` into a `SearchJob` SolidQueue task. Benchmark on a 4 GB staging VPS: median latency, max RSS under load.
5. If results match, commit. If not, fall back: (a) fp16 quantization, (b) single Puma worker + in-process, (c) external sidecar (TEI binary via systemd as escape hatch — but this is the explicit avoid-Docker fallback, not the plan).

The reranker is structurally simpler for ONNX export (single classification head, no autoregressive decode path), so if the bi-encoder export works, the reranker will too.

### Phased quality roadmap

**Phase 1 — cheap, immediate (~1 week):**

1. ✅ **DONE 2026-04-25:** Bi-encoder → Qwen3-Embedding-0.6B in production. **+26 pp MRR** demonstrated.
2. ✅ **DONE 2026-04-26:** RRF hybrid retrieval (Qwen3 dense ⊕ `pg_search` FTS). **+7.83 pp MRR / +3.18 pp NDCG** measured on 355 concepts × 2585 query variants. See [Audit results](#audit-rrf-2026-04-26) below.
3. ❌ **Wire Qwen3-Reranker-0.6B with Hotwire progressive UX** — **shelved 2026-04-26**. Reranker is decoder-style (full LLM forward pass at inference) and runs at 1-3 sec per (query, doc) pair on the prod 2 vCPU x86 VPS — top-50 rerank = 50-150 sec per search even with progressive UX. Not shippable. If pursuing reranking later, switch to encoder-style cross-encoder (`bge-reranker-base`, 110M params, ~50 ms/pair on CPU) on top of RRF.

Expected after Phase 1: MRR(name) ~0.55–0.65, MRR(best) ~0.85+. From the current 0.12 / 0.27.

#### Audit: RRF 2026-04-26

Held-out eval against `search_concepts` curated theme→verse pairs (355 concepts, 2585 query variants including aliases). Fusion: `score(d) = Σ 1/(k + rank_L(d))` over both ranked lists, k=60.

| Strategy | MRR(name) | MRR(best) | NDCG(best) |
|---|---|---|---|
| Bi-encoder alone (Qwen3) | 0.3528 | 0.7519 | 0.4236 |
| FTS alone | 0.2556 | 0.7107 | 0.3843 |
| **RRF (bi ⊕ FTS, k=60)** | **0.3971** | **0.8301** | **0.4554** |

**Lift over bi-encoder:** +7.83 pp MRR(best), +3.18 pp NDCG(best). Per-category MRR(best): `attribute` 86.7→**100.0**, `event` 66.8→**78.3**, `place` 72.5→**81.5**, `title` 85.6→**93.9**.

Reproducible via `RRF=1 EMB_TABLE=work_unit_embeddings_qwen3_06b EMB_COLUMN=embedding QUERY_PROMPT=query MODEL_PATH=Qwen/Qwen3-Embedding-0.6B bin/rails eval:thematic`.

Implementation: `Search::Strategies::SemanticMerge` runs the prod FTS + dense retrievals as before, then fuses ranks via RRF instead of the legacy α·fts + β·sem weighted blend. Existing boosts (LANG, TESTAMENT, person, pericope) and pins (alias_match, phrase-bonus FTS) layer on top of the RRF score. Rollback knob: `SEARCH_FUSION=weighted` (no redeploy needed).

**Phase 2 — more work, more headroom (~2 weeks):**

4. Hard-negative mining for Qwen3 bi-encoder + careful fine-tune (low LR ~5e-6, 1 epoch). Expect **+3 to +8 pp**. Watch for thematic regression — the alignment-pair training data risks over-specializing the embedding space.
5. Cross-encoder fine-tune on the same hard-neg pairs. Expect **+3 to +6 pp** on rerank quality.
6. Synthetic + curated thematic training data. Two sources, both training-only (not displayed on the site):
   - **OpenBible.info Topics dataset** (CC BY 4.0). Roughly 10–100× the size of our internal `search_concepts` (currently 355 concepts × 1190 verses). Use as positive theme→verse pairs for cross-encoder fine-tune and bi-encoder hard-negative anchors. Download to `tmp/training_data/openbible_topics/` (gitignored). Attribute in training scripts / model card. Don't redistribute or display.
   - **LLM-generated thematic queries** against gold verse sets, manually reviewed sample of N. Synthetic but cheap.
   Expect **+2 to +6 pp** combined.

Expected after Phase 2: MRR(name) ~0.65–0.75.

**Phase 3 — advanced, if pushing toward SOTA (~month):**

7. Domain continued pretraining on full biblical corpus. **+2 to +5 pp**, expensive compute.
8. Cross-encoder distillation: Qwen3-Reranker-8B as teacher → smaller production student. Same quality, half the latency.
9. ColBERT-style late-interaction as a third stage for hardest queries. **+2 to +5 pp** but storage tax (~5×).

Expected after Phase 3: MRR(name) ~0.75–0.80, comparable to commercial RAG.

### Reranker latency on 4 GB / 2 vCPU VPS

`Qwen3-Reranker-0.6B`, top-50, batched, int8: ~1–2 s on 2 vCPU. With progressive UX (initial bi-encoder paint in ~200 ms, reranked list streams in via Turbo Stream when SolidQueue job finishes), perceived latency is fine.

If query volume grows past CPU saturation, fall back to `bge-reranker-base` (110M, ~200–500 ms) or move reranker to a sibling box. Phase 1 explicitly does NOT need the bigger Qwen3-Reranker-4B/8B.

### Known data bugs

- ✅ **DONE 2026-04-26: Greek lemma Unicode duplicates.** Migration
  `20260426230000_merge_unicode_duplicate_lemmas` NFC-normalized 7,144
  duplicate rows across 3,572 (NFC, language) groups, summing
  frequencies into the highest-freq canonical and remapping
  `words.lemma_id` + `lemmas.related_lemma_ids` array entries.
  `Lemma#nfc_normalize_lemma` (before_validation) closes the gate
  for future imports. θρόνος is now one row, frequency 366.
  Existing UNIQUE (language, lemma) index prevents recurrence.

### Side tables (model race infra)

- `work_unit_embeddings_qwen3_06b (work_unit_id PK, embedding vector(1024))` + HNSW
- `work_unit_embeddings_bge_m3` — created during the race, dropped 2026-04-25 after Qwen3 won.
- `lib/tasks/embeddings.rake :import_side[slug,dim,path]` rebuilds either from a TSV.
- A future cleanup migration will drop the LaBSE columns (`work_units.body_embedding`, `pericopes.name_embedding`) once Qwen3 is confirmed stable in production.

### Production deploy runbook (Phase 1.1)

Code merge to master triggers `cap production deploy`, which auto-runs migrations:
- `20260425200000_add_qwen3_embedding_to_pericopes` — adds `pericopes.name_embedding_qwen3 vector(1024)` + HNSW index
- `20260425200001_create_work_unit_embeddings_qwen3` — creates the side table (empty) + HNSW index will be added by the import task

Three manual post-deploy steps (the embedding side table + ONNX model are too large for git or auto-deploy):

**1. Get the ONNX model files onto prod (~1.1 GB).**

`vendor/models/` is in `linked_dirs`, so the path lives in `shared/` and persists across releases. From dev:

```sh
# From the openscriptorium repo root on dev
rsync -avz --progress vendor/models/qwen3_embed_fused_fp16/ \
    deploy@<prod_host>:/var/www/openscriptorium/shared/vendor/models/qwen3_embed_fused_fp16/
```

After this, `current/vendor/models/qwen3_embed_fused_fp16/` resolves to the shared path and Rails can load the model.

**2. Get the corpus embeddings TSV onto prod (~6.4 GB) and import it.**

The TSV was produced on Modal during the race (`scripts/train_embeddings/modal_encode.py`). Two ways to deliver it:

a. Re-download from the Modal volume directly on prod (Modal has good bandwidth; ~5–10 min):
```sh
ssh deploy@<prod_host>
cd /var/www/openscriptorium/current
./scripts/train_embeddings/venv/bin/modal volume get \
    openscriptorium-models embeddings_qwen3_06b.tsv tmp/
```
(requires Modal CLI + creds on prod; if not set up, do (b) instead)

b. rsync from dev (~6.4 GB; depends on internet):
```sh
rsync -avz --progress tmp/embeddings_qwen3_06b.tsv \
    deploy@<prod_host>:/var/www/openscriptorium/current/tmp/embeddings_qwen3_06b.tsv
```

Then import:
```sh
ssh deploy@<prod_host>
cd /var/www/openscriptorium/current
RAILS_ENV=production bundle exec rake \
    'embeddings:import_side[qwen3_06b,1024,tmp/embeddings_qwen3_06b.tsv]'
```

This drops/recreates the side table, COPYs all 706,392 rows (~3 min), and builds the HNSW index (~15 min with `maintenance_work_mem = 4GB`; tighter on the 4 GB VPS — may need to lower to 2GB and accept longer build time).

**3. Encode pericope names locally on prod (~5–8 min).**

```sh
ssh deploy@<prod_host>
cd /var/www/openscriptorium/current
RAILS_ENV=production bundle exec rake embeddings:encode_pericopes_qwen3
```

Encodes all 3,097 pericope names via the in-process Ruby ONNX path. Validates the inference stack works on the 4 GB / 2 vCPU VPS.

### Smoke test on prod

After the three manual steps, hit a search box on the live site for a query like "Throne Room Vision". If you get Revelation 4–5 results in the top 10, the bi-encoder swap is live. The previous LaBSE deploy returned mostly literal-overlap matches and missed Rev 4 entirely on this query — so the qualitative difference should be obvious.

If anything goes wrong, `git revert <commit>` then `cap production deploy` rolls back the code. The LaBSE column data was preserved, so search resumes on LaBSE without any data work. Cleanup of the LaBSE columns happens later, after stability is confirmed.
