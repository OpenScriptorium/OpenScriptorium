"""
Modal-based LoRA fine-tune of Qwen3-Embedding-0.6B on the biblical
paraphrase / cross-language / cross-reference pair mix.

Step 1 of the "does fine-tuning move MRR?" experiment. Cheap smoke run:
LoRA (rank 16) on A10G, bf16, MAX_STEPS=500 by default. Should cost
~$1-2 and finish in ~15-30 minutes.

Prereqs (run once from repo root):
    bin/rails embeddings:export_training_data
    ./scripts/train_embeddings/venv/bin/python scripts/train_embeddings/prepare_data.py
    # -> writes tmp/embedding_training/train.jsonl + val.jsonl
    #    which this script copies into the Modal image.

Run:
    ./scripts/train_embeddings/venv/bin/modal run \\
        scripts/train_embeddings/modal_train_qwen3.py

Env vars (set before `modal run`):
    BATCH_SIZE   default 16   (Qwen3-0.6B is ~3x LaBSE size; A10G safe at 16-24)
    EPOCHS       default 1
    LR           default 1e-4 (LoRA typically wants higher LR than full FT)
    MAX_LEN      default 256  (matches production Search::EmbeddingEncoder MAX_LEN)
    MAX_STEPS    default 500  (smoke; set 0 for full epoch)
    LORA_R       default 16   (adapter rank; 8=cheaper, 32=more capacity)
    LORA_ALPHA   default 32   (scaling; convention = 2 * LORA_R)
    GPU          default A10G (A100 for bigger batch / faster full epoch)
    PRINT_EVERY  default 25
    EVAL_EVERY   default 100  (0 = only at start + end)

After the smoke finishes, look at the printed baseline vs final MRR@10.
Rule of thumb:
    +1pp or more → real signal, worth a full epoch
    -0.3pp to +0.3pp → fine-tuning on this pair mix doesn't help;
                       the pair distribution needs work first
    < -0.3pp → the LoRA is hurting; check LR / prompt asymmetry

Download the trained adapters + merged model with:
    ./scripts/train_embeddings/venv/bin/modal volume get \\
        openscriptorium-models qwen3_scripture_lora \\
        tmp/embedding_model/qwen3_scripture_lora

NOTE ON PROMPTS: Qwen3-Embedding expects an instruction prefix on queries
("Instruct: <task>\\nQuery: <text>") for its full asymmetric mode. Our
existing pair pipeline is symmetric (both sides are documents), so this
smoke run trains without prompts. If step-1 shows signal, step 2 should
regenerate pairs with an explicit query side and instruction-format them.
"""

import json
import os
import random
import time
from pathlib import Path

import modal

# ─── Modal app + image ────────────────────────────────────────────────
app = modal.App("openscriptorium-embeddings-qwen3")

image = modal.Image.debian_slim(python_version="3.12").pip_install(
    "torch==2.5.1",
    "sentence-transformers>=3.3",     # 3.3+ has better Qwen3 support
    "peft>=0.13",                     # LoRA adapters
    "datasets>=2.14",
    "accelerate>=1.1.0",
    "transformers>=4.45",
)

if modal.is_local():
    image = image.add_local_dir(
        Path(__file__).resolve().parents[2] / "tmp" / "embedding_training",
        remote_path="/training_data",
        copy=True,
    )

volume = modal.Volume.from_name("openscriptorium-models", create_if_missing=True)

GPU = os.environ.get("GPU", "A10G")


@app.function(
    image=image,
    gpu=GPU,
    volumes={"/output": volume},
    timeout=4 * 60 * 60,
)
def train_remote(
    batch_size: int = 16,
    epochs: int = 1,
    lr: float = 1e-4,
    max_len: int = 256,
    print_every: int = 25,
    eval_every: int = 100,
    max_steps: int = 500,
    lora_r: int = 16,
    lora_alpha: int = 32,
    base_model: str = "Qwen/Qwen3-Embedding-0.6B",
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
    from peft import LoraConfig, get_peft_model, PeftModel

    random.seed(42)
    log_path = Path("/output/qwen3_train.log")
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_fp = log_path.open("a", buffering=1)

    def log(msg):
        line = f"[{time.strftime('%H:%M:%S')}] {msg}"
        print(line, flush=True)
        log_fp.write(line + "\n")

    log("=" * 70)
    log("Modal Qwen3-Embedding-0.6B LoRA fine-tune (SMOKE)")
    log(f"  GPU:         {GPU}")
    log(f"  base model:  {base_model}")
    log(f"  batch size:  {batch_size}")
    log(f"  epochs:      {epochs}")
    log(f"  lr:          {lr}")
    log(f"  max length:  {max_len}")
    log(f"  max steps:   {max_steps or 'full epoch'}")
    log(f"  LoRA r:      {lora_r}  alpha: {lora_alpha}")

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

    # ─── Load model + wrap with LoRA ──────────────────────────────
    log(f"\nLoading base model {base_model}…")
    t0 = time.time()
    model = SentenceTransformer(base_model, trust_remote_code=True)
    model.max_seq_length = max_len
    log(f"  loaded in {time.time() - t0:.1f}s")

    # Qwen3-Embedding wraps a Qwen2 decoder as its transformer module.
    # LoRA targets the standard attention + FFN projection layers.
    log(f"\nAttaching LoRA (r={lora_r}, alpha={lora_alpha})…")
    inner = model[0].auto_model  # the underlying HF causal LM
    lora_cfg = LoraConfig(
        r=lora_r,
        lora_alpha=lora_alpha,
        lora_dropout=0.05,
        bias="none",
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj",
                        "gate_proj", "up_proj", "down_proj"],
        task_type=None,  # not a classification head — pooling handled outside PEFT
    )
    peft_inner = get_peft_model(inner, lora_cfg)
    model[0].auto_model = peft_inner
    trainable = sum(p.numel() for p in peft_inner.parameters() if p.requires_grad)
    total = sum(p.numel() for p in peft_inner.parameters())
    log(f"  trainable params: {trainable:,} / {total:,}  ({100*trainable/total:.2f}%)")

    # ─── MRR eval helper ──────────────────────────────────────────
    @torch.no_grad()
    def eval_mrr(k=10, sample_size=500):
        if len(val_pairs) > sample_size:
            sample = random.sample(val_pairs, sample_size)
        else:
            sample = val_pairs
        a = [p[0] for p in sample]
        b = [p[1] for p in sample]
        was_training = model.training
        model.eval()
        a_emb = model.encode(a, batch_size=32, convert_to_tensor=True,
                             show_progress_bar=False, normalize_embeddings=True)
        b_emb = model.encode(b, batch_size=32, convert_to_tensor=True,
                             show_progress_bar=False, normalize_embeddings=True)
        if was_training:
            model.train()
        sims = a_emb @ b_emb.T
        n = sims.size(0)
        diag = torch.eye(n, dtype=torch.bool, device=sims.device)
        correct = sims.diagonal().unsqueeze(1)
        sims_off = sims.masked_fill(diag, float("-inf"))
        rank = (sims_off > correct).sum(dim=1) + 1
        rr = torch.where(rank <= k, 1.0 / rank.float(),
                         torch.zeros_like(rank, dtype=torch.float))
        return rr.mean().item()

    log("\nBaseline eval (LoRA attached but zero-adapter → equivalent to zero-shot)…")
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
                t0 = time.time()
                mrr = eval_mrr()
                delta = (mrr - base_mrr) * 100
                sign = "+" if delta >= 0 else ""
                log(f"  ─── VAL @ step {step}: MRR@10 {mrr:.4f}  "
                    f"(baseline {base_mrr:.4f}, {sign}{delta:.2f}pp)  "
                    f"({time.time() - t0:.1f}s)")

    # ─── Trainer ──────────────────────────────────────────────────
    loss = MultipleNegativesRankingLoss(model)

    save_steps = int(os.environ.get("SAVE_STEPS", "200"))

    args = SentenceTransformerTrainingArguments(
        output_dir="/output/qwen3_checkpoints",
        num_train_epochs=epochs,
        per_device_train_batch_size=batch_size,
        learning_rate=lr,
        warmup_ratio=0.10,
        logging_steps=1,
        save_strategy="no" if max_steps else "steps",
        save_steps=save_steps,
        save_total_limit=2,
        report_to=[],
        max_steps=max_steps if max_steps else -1,
        disable_tqdm=True,
        dataloader_num_workers=2,
        bf16=True,
        gradient_checkpointing=True,   # trades ~20% speed for a lot of VRAM
    )

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

    existing_ckpts = sorted(Path("/output/qwen3_checkpoints").glob("checkpoint-*"))
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
    delta = (final_mrr - base_mrr) * 100
    sign = "+" if delta >= 0 else ""
    log(f"  final MRR@10: {final_mrr:.4f}  "
        f"(baseline {base_mrr:.4f}, {sign}{delta:.2f}pp)")

    # ─── Save adapters + merged model ─────────────────────────────
    adapters_path = Path("/output/qwen3_scripture_lora/adapters")
    merged_path   = Path("/output/qwen3_scripture_lora/merged")
    adapters_path.mkdir(parents=True, exist_ok=True)
    merged_path.mkdir(parents=True, exist_ok=True)

    log(f"\nSaving LoRA adapters → {adapters_path}…")
    peft_inner.save_pretrained(str(adapters_path))

    log(f"Merging adapters into base weights + saving full model → {merged_path}…")
    merged_inner = peft_inner.merge_and_unload()
    model[0].auto_model = merged_inner
    model.save(str(merged_path))
    log(f"  merged sentence-transformer saved (ready for ONNX re-export)")

    volume.commit()
    log_fp.close()

    return {
        "baseline_mrr": base_mrr,
        "final_mrr": final_mrr,
        "delta_pp": delta,
        "elapsed_min": elapsed,
        "adapters_path": str(adapters_path),
        "merged_path": str(merged_path),
        "gpu": GPU,
        "max_steps": max_steps,
    }


@app.local_entrypoint()
def main():
    result = train_remote.remote(
        batch_size=int(os.environ.get("BATCH_SIZE", "16")),
        epochs=int(os.environ.get("EPOCHS", "1")),
        lr=float(os.environ.get("LR", "1e-4")),
        max_len=int(os.environ.get("MAX_LEN", "256")),
        print_every=int(os.environ.get("PRINT_EVERY", "25")),
        eval_every=int(os.environ.get("EVAL_EVERY", "100")),
        max_steps=int(os.environ.get("MAX_STEPS", "500")),
        lora_r=int(os.environ.get("LORA_R", "16")),
        lora_alpha=int(os.environ.get("LORA_ALPHA", "32")),
    )
    print()
    print("=" * 70)
    print("REMOTE RESULT:")
    for k, v in result.items():
        print(f"  {k}: {v}")
    print()
    print("Download the trained artefacts with:")
    print("  ./scripts/train_embeddings/venv/bin/modal volume get \\")
    print("      openscriptorium-models qwen3_scripture_lora \\")
    print("      tmp/embedding_model/qwen3_scripture_lora")
    print()
    print("Then evaluate against the 355-concept task:")
    print("  MODEL_PATH=tmp/embedding_model/qwen3_scripture_lora/merged \\")
    print("    bin/rails 'eval:thematic[10]'")
