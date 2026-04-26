"""
Modal-based corpus encoding using any HuggingFace embedding model.

Reads corpus.csv from a baked-in image mount, encodes every row on GPU,
writes embeddings_<slug>.tsv to the openscriptorium-models Modal volume so
we can download it locally.

Run (from repo root):

    MODEL=BAAI/bge-m3 SLUG=bge_m3 \\
      ./scripts/train_embeddings/venv/bin/modal run --detach \\
      scripts/train_embeddings/modal_encode.py

Then:

    ./scripts/train_embeddings/venv/bin/modal volume get \\
        openscriptorium-models embeddings_bge_m3.tsv tmp/

Environment variables:
    MODEL          HF model id, OR local path under /output (e.g. labse_scripture)
    SLUG           short identifier used in output filename + DB table name
    BATCH_SIZE     encoding batch size (default 64; smaller for big models)
    OUTPUT_DIM     truncate to first N dims (Matryoshka). Default = full.
    GPU            'A10G' (default), 'L4', 'A100', 'A100-80GB', 'T4'
    PROMPT_NAME    optional prompt key from the model's prompts.json (e.g. 'document')
"""

import os
import time
from pathlib import Path

import modal

app = modal.App("openscriptorium-encode")

image = modal.Image.debian_slim(python_version="3.12").pip_install(
    "torch>=2.6",
    "sentence-transformers>=3.3",
    "transformers>=4.45",
    "accelerate>=1.1",
)

if modal.is_local():
    image = image.add_local_file(
        Path(__file__).resolve().parents[2] / "tmp" / "embedding_training" / "corpus.csv",
        remote_path="/corpus.csv",
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
def encode_remote(
    model_id: str,
    slug: str,
    batch_size: int = 64,
    output_dim: int = 0,
    prompt_name: str = "",
):
    import csv

    from sentence_transformers import SentenceTransformer

    log_path = Path(f"/output/encode_{slug}.log")
    log_fp = log_path.open("a", buffering=1)

    def log(msg):
        line = f"[{time.strftime('%H:%M:%S')}] {msg}"
        print(line, flush=True)
        log_fp.write(line + "\n")

    log("=" * 70)
    log(f"Modal encode  slug={slug}  GPU={GPU}  batch={batch_size}")
    log(f"  model_id:  {model_id}")
    log(f"  output_dim: {output_dim or 'full'}")
    log(f"  prompt:    {prompt_name or '(none)'}")

    # If model_id is a relative name and a directory exists under /output, use it.
    candidate_local = Path(f"/output/{model_id}")
    resolved = str(candidate_local) if candidate_local.is_dir() else model_id
    log(f"Loading model from {resolved}...")
    t0 = time.time()
    model = SentenceTransformer(resolved, device="cuda", trust_remote_code=True)
    # Many embedders default to enormous max_seq_length (Qwen3: 32768, bge-m3: 8192).
    # With dynamic padding, a single long-commentary row in a batch blows VRAM.
    # 256 tokens is more than enough for biblical verses (mean ~40, p99 ~400 chars
    # of text → ~120 tokens). Long commentary gets truncated at the tail; the
    # opening of a passage is the most semantically distinctive portion anyway.
    max_seq_len = int(os.environ.get("MAX_SEQ_LEN", "256"))
    model.max_seq_length = max_seq_len
    log(f"  loaded in {time.time() - t0:.1f}s, device={model.device}, "
        f"native_dim={model.get_sentence_embedding_dimension()}, "
        f"max_seq_length={model.max_seq_length}")

    in_path = Path("/corpus.csv")
    out_path = Path(f"/output/embeddings_{slug}.tsv")
    log(f"Reading {in_path} ({in_path.stat().st_size / 1e6:.0f} MB)...")

    encode_kwargs = {"batch_size": batch_size, "show_progress_bar": False}
    if prompt_name:
        encode_kwargs["prompt_name"] = prompt_name

    # ─── Resume: scan existing output (if any) for already-encoded IDs ───
    # A10G GPUs are preemptible; Modal re-invokes main() from scratch on
    # restart. Without this block we'd discard prior work. The volume itself
    # persists across restarts, so the partial output file is our checkpoint.
    encoded_ids = set()
    out_mode = "w"
    if out_path.exists():
        log(f"Found existing {out_path} — resuming...")
        last_good_pos = 0
        with out_path.open("rb") as ef:
            for raw_line in ef:
                if not raw_line.endswith(b"\n"):
                    # Torn final line from a kill mid-write — drop it.
                    break
                tab = raw_line.find(b"\t")
                if tab > 0:
                    encoded_ids.add(raw_line[:tab].decode())
                last_good_pos = ef.tell()
        # Truncate any torn tail bytes so we append cleanly.
        if last_good_pos < out_path.stat().st_size:
            with out_path.open("r+b") as ef:
                ef.truncate(last_good_pos)
            log(f"  truncated {out_path.stat().st_size - last_good_pos} torn bytes")
        log(f"  resume: {len(encoded_ids)} rows already encoded")
        out_mode = "a"

    ids = []
    texts = []
    n_total = len(encoded_ids)  # count toward progress so meter is honest
    n_skipped = 0
    n_new = 0
    t_start = time.time()
    flush_every = 4096

    with out_path.open(out_mode) as out, in_path.open(newline="") as f:
        reader = csv.reader(f)

        def flush():
            nonlocal n_total, n_new
            if not ids:
                return
            vecs = model.encode(texts, **encode_kwargs)
            if output_dim and output_dim < vecs.shape[1]:
                vecs = vecs[:, :output_dim]
            vecs = vecs.tolist()
            for uid, vec in zip(ids, vecs):
                out.write(uid)
                out.write("\t[")
                out.write(",".join(f"{v:.6f}" for v in vec))
                out.write("]\n")
            out.flush()  # ensure bytes hit the volume's host buffer
            n_total += len(ids)
            n_new   += len(ids)
            ids.clear()
            texts.clear()
            # Make this batch durable: on preemption, the next invocation
            # sees these rows and skips them.
            volume.commit()

        for row in reader:
            if len(row) < 2:
                continue
            uid = row[0]
            if uid in encoded_ids:
                n_skipped += 1
                continue
            ids.append(uid)
            texts.append(row[1])
            if len(ids) >= flush_every:
                flush()
                elapsed = time.time() - t_start
                rate = n_new / elapsed if elapsed > 0 else 0
                log(f"  encoded {n_total} (this run +{n_new}, skipped {n_skipped})  rate {rate:.0f} samp/s")
        flush()

    elapsed = time.time() - t_start
    log(f"DONE: {n_total} samples in {elapsed:.0f}s ({n_total/elapsed:.0f} samp/s)")
    log(f"Output: {out_path} ({out_path.stat().st_size / 1e6:.0f} MB)")
    volume.commit()

    return {
        "slug": slug,
        "model_id": model_id,
        "encoded": n_total,
        "elapsed_sec": elapsed,
        "rate_samp_s": n_total / elapsed if elapsed > 0 else 0,
        "out_path": str(out_path),
        "output_dim": output_dim or model.get_sentence_embedding_dimension(),
    }


@app.local_entrypoint()
def main():
    model_id    = os.environ.get("MODEL")    or "BAAI/bge-m3"
    slug        = os.environ.get("SLUG")     or "bge_m3"
    batch_size  = int(os.environ.get("BATCH_SIZE", "64"))
    output_dim  = int(os.environ.get("OUTPUT_DIM", "0"))
    prompt_name = os.environ.get("PROMPT_NAME", "")

    result = encode_remote.remote(
        model_id=model_id, slug=slug, batch_size=batch_size,
        output_dim=output_dim, prompt_name=prompt_name,
    )
    print()
    print("=" * 70)
    print("REMOTE RESULT:")
    for k, v in result.items():
        print(f"  {k}: {v}")
    print()
    print(f"Download with:")
    print(f"  ./scripts/train_embeddings/venv/bin/modal volume get \\")
    print(f"      openscriptorium-models embeddings_{slug}.tsv tmp/")
