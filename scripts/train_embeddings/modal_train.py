"""
Modal-based fine-tune of LaBSE on the biblical paraphrase pairs.

The 8 GB local Mac is too small for LaBSE's full Adam state. This runs the
same training loop on a Modal A10G (24 GB VRAM) where there's headroom for
batch 32 + fp32 Adam. The trained model is saved to a Modal Volume so we
can download it locally afterward and feed it into `rake embeddings:encode_corpus`.

Run (from repo root, using the venv we created for the local script):

    ./scripts/train_embeddings/venv/bin/modal run scripts/train_embeddings/modal_train.py

After it finishes:

    ./scripts/train_embeddings/venv/bin/modal volume get \\
        openscriptorium-models labse_scripture \\
        tmp/embedding_model/labse_scripture

Env vars (set before `modal run`):
    BATCH_SIZE   default 32 (A10G has 24 GB; comfortable)
    EPOCHS       default 1
    LR           default 2e-5
    MAX_LEN      default 128
    PRINT_EVERY  default 50
    EVAL_EVERY   default 1000  (0 = epoch-end only)
    MAX_STEPS    0 = full epoch; >0 = smoke test
    GPU          'A10G' (default), 'L4', 'A100', 'T4'
"""

import json
import os
import random
import time
from pathlib import Path

import modal

# ─── Modal app + image ────────────────────────────────────────────────
app = modal.App("openscriptorium-embeddings")

image = modal.Image.debian_slim(python_version="3.12").pip_install(
    "torch==2.5.1",
    "sentence-transformers>=3.0",
    "datasets>=2.14",
    "accelerate>=1.1.0",
    "transformers>=4.40",
)

if modal.is_local():
    image = image.add_local_dir(
        Path(__file__).resolve().parents[2] / "tmp" / "embedding_training",
        remote_path="/training_data",
        copy=True,
    )

# Persistent storage for the trained model. Survives across runs so we can
# download it with `modal volume get` after the function finishes.
volume = modal.Volume.from_name("openscriptorium-models", create_if_missing=True)

GPU = os.environ.get("GPU", "A10G")


# ─── Training function (runs on Modal) ────────────────────────────────
@app.function(
    image=image,
    gpu=GPU,
    volumes={"/output": volume},
    timeout=4 * 60 * 60,   # 4 hours max
)
def train_remote(
    batch_size: int = 32,
    epochs: int = 1,
    lr: float = 2e-5,
    max_len: int = 128,
    print_every: int = 50,
    eval_every: int = 1000,
    max_steps: int = 0,
    base_model: str = "sentence-transformers/LaBSE",
):
    import torch
    from datasets import Dataset
    from sentence_transformers import (
        SentenceTransformer,
        SentenceTransformerTrainer,
        SentenceTransformerTrainingArguments,
    )
    from sentence_transformers.losses import MultipleNegativesRankingLoss
    from transformers import TrainerCallback

    random.seed(42)
    log_path = Path("/output/train.log")
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_fp = log_path.open("a", buffering=1)

    def log(msg):
        line = f"[{time.strftime('%H:%M:%S')}] {msg}"
        print(line, flush=True)
        log_fp.write(line + "\n")

    log("=" * 70)
    log("Modal LaBSE fine-tune")
    log(f"  GPU:         {GPU}")
    log(f"  base model:  {base_model}")
    log(f"  batch size:  {batch_size}")
    log(f"  epochs:      {epochs}")
    log(f"  lr:          {lr}")
    log(f"  max length:  {max_len}")

    # ─── Load data ────────────────────────────────────────────────
    train_path = Path("/training_data/train.jsonl")
    val_path   = Path("/training_data/val.jsonl")

    log(f"\nLoading {train_path}…")
    train_rows = []
    with train_path.open() as f:
        for line in f:
            row = json.loads(line)
            train_rows.append({"anchor": row["a"], "positive": row["b"]})
    train_dataset = Dataset.from_list(train_rows)
    log(f"  {len(train_dataset)} train rows")

    val_pairs = []
    with val_path.open() as f:
        for line in f:
            row = json.loads(line)
            val_pairs.append((row["a"], row["b"]))
    log(f"  {len(val_pairs)} val pairs")

    # ─── Load model ───────────────────────────────────────────────
    log(f"\nLoading base model {base_model}…")
    t0 = time.time()
    model = SentenceTransformer(base_model)
    model.max_seq_length = max_len
    log(f"  loaded in {time.time() - t0:.1f}s")

    # ─── MRR eval helper ──────────────────────────────────────────
    @torch.no_grad()
    def eval_mrr(k=10, sample_size=500):
        if len(val_pairs) > sample_size:
            sample = random.sample(val_pairs, sample_size)
        else:
            sample = val_pairs
        a = [p[0] for p in sample]
        b = [p[1] for p in sample]
        a_emb = model.encode(a, batch_size=64, convert_to_tensor=True,
                             show_progress_bar=False, normalize_embeddings=True)
        b_emb = model.encode(b, batch_size=64, convert_to_tensor=True,
                             show_progress_bar=False, normalize_embeddings=True)
        sims = a_emb @ b_emb.T
        n = sims.size(0)
        diag = torch.eye(n, dtype=torch.bool, device=sims.device)
        correct = sims.diagonal().unsqueeze(1)
        sims_off = sims.masked_fill(diag, float("-inf"))
        rank = (sims_off > correct).sum(dim=1) + 1
        rr = torch.where(rank <= k, 1.0 / rank.float(),
                         torch.zeros_like(rank, dtype=torch.float))
        return rr.mean().item()

    log("\nBaseline eval (untuned)…")
    t0 = time.time()
    base_mrr = eval_mrr()
    log(f"  baseline MRR@10: {base_mrr:.4f}  ({time.time() - t0:.1f}s)")

    # ─── Live-logging callback ────────────────────────────────────
    class LiveLog(TrainerCallback):
        def __init__(self):
            self.t_last = None
            self.last_step = 0

        def on_train_begin(self, args, state, control, **kwargs):
            self.t_last = time.time()
            self.last_step = 0

        def on_log(self, args, state, control, logs=None, **kwargs):
            if not logs or "loss" not in logs:
                return
            step = state.global_step
            if step % print_every != 0:
                return
            now = time.time()
            interval = now - self.t_last
            steps_done = step - self.last_step
            rate = (steps_done * batch_size) / max(0.001, interval)
            total = state.max_steps or 1
            eta_min = (total - step) * (interval / max(1, steps_done)) / 60
            lr_now = logs.get("learning_rate", 0)
            log(f"  step {step}/{total}  loss {logs['loss']:.4f}  "
                f"lr {lr_now:.2e}  {rate:.1f} samp/s  eta {eta_min:.1f}m")
            self.t_last = now
            self.last_step = step

        def on_step_end(self, args, state, control, **kwargs):
            if not eval_every:
                return
            step = state.global_step
            if step > 0 and step % eval_every == 0:
                model.eval()
                t0 = time.time()
                mrr = eval_mrr()
                log(f"  ─── VAL @ step {step}: MRR@10 {mrr:.4f}  "
                    f"(baseline {base_mrr:.4f}, "
                    f"+{(mrr - base_mrr) * 100:.2f}pp)  "
                    f"({time.time() - t0:.1f}s)")
                model.train()

    # ─── Trainer ──────────────────────────────────────────────────
    loss = MultipleNegativesRankingLoss(model)

    # save_steps determines max wasted compute on a preempt: at A10G ~150
    # steps/sec we save every ~6-7 sec wall — so worst-case loss ≈ save_steps
    # × ~6 sec. 1000 steps ≈ 1.7 min wasted per preempt.
    save_steps = int(os.environ.get("SAVE_STEPS", "1000"))

    args = SentenceTransformerTrainingArguments(
        output_dir="/output/checkpoints",
        num_train_epochs=epochs,
        per_device_train_batch_size=batch_size,
        learning_rate=lr,
        warmup_steps=0.10,            # float < 1 = ratio in Transformers v5
        logging_steps=1,
        save_strategy="no" if max_steps else "steps",
        save_steps=save_steps,
        save_total_limit=2,
        report_to=[],
        max_steps=max_steps if max_steps else -1,
        disable_tqdm=True,
        dataloader_num_workers=2,
        bf16=True,                    # A10G supports bf16 well
    )

    # Make every save_steps checkpoint durable: write to volume immediately,
    # otherwise a preempt mid-epoch loses everything since the last fsync
    # (which on Modal volumes only happens on volume.commit()).
    class VolumeCommitCallback(TrainerCallback):
        def on_save(self, args, state, control, **kwargs):
            log(f"  checkpoint saved at step {state.global_step} → committing volume")
            volume.commit()

    trainer = SentenceTransformerTrainer(
        model=model,
        args=args,
        train_dataset=train_dataset,
        loss=loss,
        callbacks=[LiveLog(), VolumeCommitCallback()],
    )

    # Resume from any existing checkpoint in the output dir (preemption-safe).
    existing_ckpts = sorted(Path("/output/checkpoints").glob("checkpoint-*"))
    if existing_ckpts and not max_steps:
        log(f"\nResuming from {existing_ckpts[-1]} ({len(existing_ckpts)} checkpoint(s) on volume)")
        resume_kwargs = {"resume_from_checkpoint": True}
    else:
        log("\nStarting training…\n")
        resume_kwargs = {}
    t0 = time.time()
    trainer.train(**resume_kwargs)
    elapsed = (time.time() - t0) / 60
    log(f"\nTraining done in {elapsed:.1f} min")

    log("\nFinal eval…")
    final_mrr = eval_mrr()
    log(f"  final MRR@10: {final_mrr:.4f}  "
        f"(baseline {base_mrr:.4f}, +{(final_mrr - base_mrr) * 100:.2f}pp)")

    out_path = Path("/output/labse_scripture")
    out_path.mkdir(parents=True, exist_ok=True)
    model.save(str(out_path))
    log(f"\nFinal model saved to {out_path} (Modal volume openscriptorium-models)")
    log_fp.close()

    # Ensure volume contents are flushed
    volume.commit()
    return {"baseline_mrr": base_mrr, "final_mrr": final_mrr,
            "elapsed_min": elapsed, "out_path": str(out_path)}


# ─── Local entrypoint ─────────────────────────────────────────────────
@app.local_entrypoint()
def main():
    """Kick off the remote training job. Output streams here in real time."""
    result = train_remote.remote(
        batch_size=int(os.environ.get("BATCH_SIZE", "32")),
        epochs=int(os.environ.get("EPOCHS", "1")),
        lr=float(os.environ.get("LR", "2e-5")),
        max_len=int(os.environ.get("MAX_LEN", "128")),
        print_every=int(os.environ.get("PRINT_EVERY", "50")),
        eval_every=int(os.environ.get("EVAL_EVERY", "1000")),
        max_steps=int(os.environ.get("MAX_STEPS", "0")),
    )
    print()
    print("=" * 70)
    print("REMOTE RESULT:")
    for k, v in result.items():
        print(f"  {k}: {v}")
    print()
    print("Download the model with:")
    print("  ./scripts/train_embeddings/venv/bin/modal volume get \\")
    print("      openscriptorium-models labse_scripture \\")
    print("      tmp/embedding_model/labse_scripture")
