#!/usr/bin/env python3
"""
Filter and sample the exported JSONL training pairs into a clean train/val
split for sentence-transformer fine-tuning.

Reads from tmp/embedding_training/*.jsonl (output of `rake embeddings:export_training_data`)
and writes:
  - tmp/embedding_training/train.jsonl
  - tmp/embedding_training/val.jsonl

Each line is a JSON object: {"a": "...", "b": "...", "source": "..."}.

Run with no args; tweak the SAMPLE_SIZES dict below to change composition.
"""

import json
import random
import sys
from pathlib import Path

random.seed(42)

REPO = Path(__file__).resolve().parents[2]
INPUT_DIR = REPO / "tmp" / "embedding_training"
OUTPUT_DIR = INPUT_DIR

# How many pairs to keep from each source.
# 0 means "all". Negative not supported.
SAMPLE_SIZES = {
    "paraphrase_pairs.jsonl":      0,        # all 78k — same verse, different English translation. High quality.
    "verse_crosslang_pairs.jsonl": 0,        # all 58k — Hebrew/Greek ↔ English at verse level. Cross-lingual signal.
    "extra_crosslang_pairs.jsonl": 0,        # Luther/Segond/Vulgate ↔ English. May or may not exist.
    "crossref_pairs.jsonl":        50_000,   # 686k available, but most are weak parallels. Sample top by confidence.
    "hebrew_english_pairs.jsonl":  10_000,   # 288k word-level. Useful but noisy. Cap.
    "greek_english_pairs.jsonl":   10_000,   # 123k word-level. Cap.
}

# Crossref confidence threshold (only applies when sampling crossref_pairs).
CROSSREF_MIN_CONFIDENCE = 0.5

# Validation split.
VAL_FRACTION = 0.02
MAX_VAL_PAIRS = 2000

# Drop pairs where either side is too short or trivially identical.
MIN_CHARS = 10
MAX_CHARS = 1000


def normalize_text(s):
    if s is None:
        return ""
    return " ".join(str(s).split())


def keep_pair(a, b):
    if not a or not b:
        return False
    if len(a) < MIN_CHARS or len(b) < MIN_CHARS:
        return False
    if len(a) > MAX_CHARS or len(b) > MAX_CHARS:
        return False
    if a == b:
        return False
    return True


def load_pairs(filename):
    """Yield (a, b, source) tuples from a JSONL file with our schema variations."""
    path = INPUT_DIR / filename
    if not path.exists():
        print(f"  [skip] {filename} (not found)")
        return
    n_in = n_out = 0
    confidences = []
    with path.open() as f:
        for line in f:
            n_in += 1
            row = json.loads(line)
            # The exporter uses different field names per source — handle them all.
            if "text1" in row and "text2" in row:
                a, b = row["text1"], row["text2"]
            elif "source" in row and "target" in row:
                a, b = row["source"], row["target"]
            else:
                continue

            # Crossref-specific: filter by confidence.
            if filename == "crossref_pairs.jsonl":
                conf = float(row.get("confidence") or 0.0)
                confidences.append(conf)
                if conf < CROSSREF_MIN_CONFIDENCE:
                    continue

            a, b = normalize_text(a), normalize_text(b)
            if not keep_pair(a, b):
                continue
            n_out += 1
            yield (a, b, filename.replace("_pairs.jsonl", ""))
    extra = ""
    if confidences:
        kept = sum(1 for c in confidences if c >= CROSSREF_MIN_CONFIDENCE)
        extra = f" (confidence ≥ {CROSSREF_MIN_CONFIDENCE}: {kept}/{len(confidences)})"
    print(f"  {filename.ljust(34)} {n_in} read, {n_out} kept{extra}")


def sample(pairs, n):
    pairs = list(pairs)
    if n == 0 or n >= len(pairs):
        random.shuffle(pairs)
        return pairs
    return random.sample(pairs, n)


def main():
    if not INPUT_DIR.exists():
        print(f"ERROR: input directory {INPUT_DIR} does not exist.")
        print("Run `bundle exec rake embeddings:export_training_data` first.")
        sys.exit(1)

    print(f"Reading from {INPUT_DIR}")
    print(f"Writing to   {OUTPUT_DIR}")
    print()

    all_pairs = []
    for filename, target_n in SAMPLE_SIZES.items():
        before = len(all_pairs)
        candidates = list(load_pairs(filename))
        sampled = sample(candidates, target_n)
        all_pairs.extend(sampled)
        added = len(all_pairs) - before
        print(f"    → kept {added} after sampling (target {target_n if target_n else 'all'})")

    print()
    print(f"Total pairs before dedup: {len(all_pairs)}")

    # Dedup by (a, b) — same anchor/positive can show up in multiple sources.
    seen = set()
    deduped = []
    for a, b, src in all_pairs:
        key = (a, b)
        if key in seen:
            continue
        seen.add(key)
        deduped.append((a, b, src))
    print(f"After dedup:               {len(deduped)}")

    # Shuffle and split.
    random.shuffle(deduped)
    n_val = min(MAX_VAL_PAIRS, int(len(deduped) * VAL_FRACTION))
    val = deduped[:n_val]
    train = deduped[n_val:]

    print()
    print(f"Train: {len(train)}")
    print(f"Val:   {len(val)}")

    # Source breakdown of train set.
    src_counts = {}
    for _, _, s in train:
        src_counts[s] = src_counts.get(s, 0) + 1
    print("\nTrain composition:")
    for s, c in sorted(src_counts.items(), key=lambda x: -x[1]):
        print(f"  {s.ljust(28)} {c}")

    train_path = OUTPUT_DIR / "train.jsonl"
    val_path = OUTPUT_DIR / "val.jsonl"
    with train_path.open("w") as f:
        for a, b, s in train:
            f.write(json.dumps({"a": a, "b": b, "source": s}) + "\n")
    with val_path.open("w") as f:
        for a, b, s in val:
            f.write(json.dumps({"a": a, "b": b, "source": s}) + "\n")

    print(f"\nWrote {train_path} ({train_path.stat().st_size / 1024 / 1024:.1f} MB)")
    print(f"Wrote {val_path} ({val_path.stat().st_size / 1024 / 1024:.1f} MB)")


if __name__ == "__main__":
    main()
