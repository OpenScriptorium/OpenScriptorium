#!/usr/bin/env python3
"""
Fine-tune a sentence-transformer on the biblical paraphrase pairs prepared
by prepare_data.py. Designed for local Apple-Silicon training with the MPS
backend; falls back to CPU.

Live progress is printed every PRINT_EVERY steps with loss, samples/sec,
and ETA. The same lines are mirrored to scripts/train_embeddings/train.log
so you can `tail -f` it from another terminal.

Run:
    ./venv/bin/python scripts/train_embeddings/train.py
    BATCH_SIZE=8 EPOCHS=1 ./venv/bin/python scripts/train_embeddings/train.py
    MAX_STEPS=20 BATCH_SIZE=4 ./venv/bin/python scripts/train_embeddings/train.py   # smoke

Env vars:
    BASE_MODEL    sentence-transformer name or local path (default: sentence-transformers/LaBSE)
    OUTPUT_DIR    where to save the trained model (default: tmp/embedding_model/labse_scripture)
    BATCH_SIZE    per-step batch (default 16; drop to 8 if OOM)
    EPOCHS        training epochs (default 1)
    LR            learning rate (default 2e-5)
    MAX_LEN       max input tokens (default 128)
    DEVICE        'mps' | 'cpu' (default: auto)
    PRINT_EVERY   stdout log frequency in steps (default 50)
    EVAL_EVERY    validation frequency in steps (default 1000; 0 = only at epoch end)
    MAX_STEPS     0 = train full epochs; >0 = smoke test cap
"""

import json
import os
import random
import time
from pathlib import Path

import torch
from datasets import Dataset
from sentence_transformers import (
    SentenceTransformer,
    SentenceTransformerTrainer,
    SentenceTransformerTrainingArguments,
)
from sentence_transformers.losses import MultipleNegativesRankingLoss
from transformers import TrainerCallback

REPO = Path(__file__).resolve().parents[2]
TRAIN_PATH = REPO / "tmp" / "embedding_training" / "train.jsonl"
VAL_PATH   = REPO / "tmp" / "embedding_training" / "val.jsonl"

# ─── Config ────────────────────────────────────────────────────────────
BASE_MODEL  = os.environ.get("BASE_MODEL", "sentence-transformers/LaBSE")
OUTPUT_DIR  = Path(os.environ.get("OUTPUT_DIR",
                   REPO / "tmp" / "embedding_model" / "labse_scripture"))
BATCH_SIZE  = int(os.environ.get("BATCH_SIZE", "16"))
EPOCHS      = int(os.environ.get("EPOCHS", "1"))
LR          = float(os.environ.get("LR", "2e-5"))
MAX_LEN     = int(os.environ.get("MAX_LEN", "128"))
PRINT_EVERY = int(os.environ.get("PRINT_EVERY", "50"))
EVAL_EVERY  = int(os.environ.get("EVAL_EVERY", "1000"))
MAX_STEPS   = int(os.environ.get("MAX_STEPS", "0"))
WARMUP_PCT  = 0.10

LOG_PATH = REPO / "scripts" / "train_embeddings" / "train.log"
random.seed(42)


# ─── Logging ───────────────────────────────────────────────────────────
class Logger:
    def __init__(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.fp = path.open("a", buffering=1)

    def __call__(self, msg):
        line = f"[{time.strftime('%H:%M:%S')}] {msg}"
        print(line, flush=True)
        self.fp.write(line + "\n")

    def close(self):
        self.fp.close()


# ─── Data ──────────────────────────────────────────────────────────────
def load_dataset(path):
    """JSONL with {a, b, source} → HF Dataset with anchor/positive columns."""
    rows = []
    with path.open() as f:
        for line in f:
            row = json.loads(line)
            rows.append({"anchor": row["a"], "positive": row["b"]})
    return Dataset.from_list(rows)


def load_val_pairs(path):
    """Plain list of (anchor, positive) tuples for our MRR eval."""
    pairs = []
    with path.open() as f:
        for line in f:
            row = json.loads(line)
            pairs.append((row["a"], row["b"]))
    return pairs


# ─── Eval: MRR@10 ──────────────────────────────────────────────────────
@torch.no_grad()
def eval_mrr(model, val_pairs, k=10, sample_size=500):
    """Sample N val pairs; embed all anchors and positives. For each anchor,
    rank its positive against all positives in the sample. Return MRR@k."""
    if len(val_pairs) > sample_size:
        sample = random.sample(val_pairs, sample_size)
    else:
        sample = val_pairs
    anchors   = [p[0] for p in sample]
    positives = [p[1] for p in sample]
    a_emb = model.encode(anchors, batch_size=32, convert_to_tensor=True,
                         show_progress_bar=False, normalize_embeddings=True)
    p_emb = model.encode(positives, batch_size=32, convert_to_tensor=True,
                         show_progress_bar=False, normalize_embeddings=True)
    sims = a_emb @ p_emb.T  # [n, n]
    n = sims.size(0)
    diag = torch.eye(n, dtype=torch.bool, device=sims.device)
    correct = sims.diagonal().unsqueeze(1)
    sims_off = sims.masked_fill(diag, float("-inf"))
    rank = (sims_off > correct).sum(dim=1) + 1
    rr = torch.where(rank <= k, 1.0 / rank.float(),
                     torch.zeros_like(rank, dtype=torch.float))
    return rr.mean().item()


# ─── Live-logging callback ─────────────────────────────────────────────
class LiveLogCallback(TrainerCallback):
    """Override Trainer's default logger output with our own format that
    includes samples/sec, ETA, and periodic MRR eval against val pairs."""

    def __init__(self, log, model, val_pairs, base_mrr, batch_size,
                 print_every, eval_every):
        self.log = log
        self.model = model
        self.val_pairs = val_pairs
        self.base_mrr = base_mrr
        self.batch_size = batch_size
        self.print_every = print_every
        self.eval_every = eval_every
        self.t_start = None
        self.t_last = None

    def on_train_begin(self, args, state, control, **kwargs):
        self.t_start = time.time()
        self.t_last = self.t_start

    def on_log(self, args, state, control, logs=None, **kwargs):
        if not logs or "loss" not in logs:
            return
        step = state.global_step
        if step % self.print_every != 0:
            return
        now = time.time()
        interval = now - self.t_last
        rate = (self.print_every * self.batch_size) / max(0.001, interval)
        total = state.max_steps or 1
        eta_min = (total - step) * (interval / max(1, self.print_every)) / 60
        lr = logs.get("learning_rate", 0)
        self.log(f"  step {step}/{total}  loss {logs['loss']:.4f}  "
                 f"lr {lr:.2e}  {rate:.1f} samp/s  eta {eta_min:.1f}m")
        self.t_last = now

    def on_step_end(self, args, state, control, **kwargs):
        if not self.eval_every:
            return
        step = state.global_step
        if step > 0 and step % self.eval_every == 0:
            self.model.eval()
            t0 = time.time()
            mrr = eval_mrr(self.model, self.val_pairs)
            self.log(f"  ─── VAL @ step {step}: MRR@10 {mrr:.4f}  "
                     f"(baseline {self.base_mrr:.4f}, "
                     f"+{(mrr - self.base_mrr) * 100:.2f}pp)  "
                     f"({time.time() - t0:.1f}s)")
            self.model.train()


# ─── Main ──────────────────────────────────────────────────────────────
def pick_device():
    explicit = os.environ.get("DEVICE")
    if explicit:
        return explicit
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def main():
    log = Logger(LOG_PATH)
    try:
        log("=" * 70)
        log("Embedding fine-tune")
        log(f"  base model:  {BASE_MODEL}")
        log(f"  output dir:  {OUTPUT_DIR}")
        log(f"  batch size:  {BATCH_SIZE}")
        log(f"  epochs:      {EPOCHS}")
        log(f"  lr:          {LR}")
        log(f"  max length:  {MAX_LEN}")
        device = pick_device()
        log(f"  device:      {device}")

        log(f"\nLoading {TRAIN_PATH.name}…")
        train_dataset = load_dataset(TRAIN_PATH)
        log(f"  {len(train_dataset)} train rows")
        val_pairs = load_val_pairs(VAL_PATH)
        log(f"  {len(val_pairs)} val pairs")

        log(f"\nLoading base model {BASE_MODEL}…")
        t0 = time.time()
        model = SentenceTransformer(BASE_MODEL, device=device)
        model.max_seq_length = MAX_LEN
        log(f"  loaded in {time.time() - t0:.1f}s")

        log("\nBaseline eval (untuned)…")
        t0 = time.time()
        base_mrr = eval_mrr(model, val_pairs)
        log(f"  baseline MRR@10: {base_mrr:.4f}  ({time.time() - t0:.1f}s)")

        loss = MultipleNegativesRankingLoss(model)
        args = SentenceTransformerTrainingArguments(
            output_dir=str(OUTPUT_DIR.with_name(OUTPUT_DIR.name + "_ckpts")),
            num_train_epochs=EPOCHS,
            per_device_train_batch_size=BATCH_SIZE,
            learning_rate=LR,
            warmup_steps=WARMUP_PCT,  # float < 1 = ratio in Transformers v5
            logging_steps=1,                # callback decides what to print
            save_strategy="epoch" if not MAX_STEPS else "no",
            save_total_limit=1,
            report_to=[],
            max_steps=MAX_STEPS if MAX_STEPS else -1,
            disable_tqdm=True,
            dataloader_num_workers=0,
            fp16=False,                     # MPS does not support fp16 autocast cleanly
            bf16=False,
        )

        trainer = SentenceTransformerTrainer(
            model=model,
            args=args,
            train_dataset=train_dataset,
            loss=loss,
            callbacks=[LiveLogCallback(
                log, model, val_pairs, base_mrr,
                batch_size=BATCH_SIZE,
                print_every=PRINT_EVERY,
                eval_every=EVAL_EVERY,
            )],
        )

        log("\nStarting training…\n")
        t0 = time.time()
        trainer.train()
        elapsed = (time.time() - t0) / 60

        log(f"\nTraining done in {elapsed:.1f} min")

        log("\nFinal eval…")
        final_mrr = eval_mrr(model, val_pairs)
        log(f"  final MRR@10: {final_mrr:.4f}  "
            f"(baseline {base_mrr:.4f}, +{(final_mrr - base_mrr) * 100:.2f}pp)")

        OUTPUT_DIR.parent.mkdir(parents=True, exist_ok=True)
        model.save(str(OUTPUT_DIR))
        log(f"\nFinal model saved to {OUTPUT_DIR}")
    finally:
        log.close()


if __name__ == "__main__":
    main()
