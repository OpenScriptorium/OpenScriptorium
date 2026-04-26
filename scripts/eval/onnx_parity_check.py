"""
ONNX parity check for Qwen3-Embedding-0.6B.

Encodes the same set of test queries via:
  (1) Python sentence-transformers (PyTorch reference)
  (2) The exported ONNX model + manual pooling/normalize via onnxruntime

Compares cosine similarity between (1) and (2) to verify the export is faithful.
Expected:
  fp32  cosine_sim > 0.999
  int8  cosine_sim > 0.99    (run separately after quantization)

Usage:
  python scripts/eval/onnx_parity_check.py vendor/models/qwen3_embed
"""
import sys
import time

import numpy as np
import onnxruntime as ort
from sentence_transformers import SentenceTransformer
from transformers import AutoTokenizer


HF_MODEL = "Qwen/Qwen3-Embedding-0.6B"

# Mix of biblical and generic queries to stress different paths.
TEST_QUERIES = [
    "In the beginning God created the heavens and the earth",
    "Throne Room Vision",
    "Faith Without Works Is Dead",
    "The Crucifixion",
    "ἀγάπη",
    "שָׁלוֹם",
    "Love your neighbor as yourself",
    "Beatitudes",
    "Seven Churches of Asia",
    "King of Kings",
] * 10  # 100 queries total


def mean_pool(token_embeds: np.ndarray, attention_mask: np.ndarray) -> np.ndarray:
    """Mean-pool token embeddings, masked by attention_mask."""
    mask = attention_mask[..., None].astype(np.float32)  # (B, T, 1)
    summed = (token_embeds * mask).sum(axis=1)
    counts = mask.sum(axis=1).clip(min=1e-9)
    return summed / counts


def l2_normalize(x: np.ndarray) -> np.ndarray:
    norm = np.linalg.norm(x, axis=-1, keepdims=True).clip(min=1e-12)
    return x / norm


def cosine_sim(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """Row-wise cosine similarity between two normalized arrays."""
    return (a * b).sum(axis=-1)


def main():
    onnx_dir = sys.argv[1] if len(sys.argv) > 1 else "vendor/models/qwen3_embed"
    # The quantized export uses a different filename; pick whichever is present.
    import os
    candidate_files = ["model.onnx", "model_quantized.onnx"]
    model_file = next(
        (f for f in candidate_files if os.path.exists(f"{onnx_dir}/{f}")),
        None,
    )
    if model_file is None:
        print(f"ERROR: no .onnx file found in {onnx_dir}")
        return 2
    is_quantized = "quantized" in model_file
    is_fp16 = "fp16" in onnx_dir.lower()
    if is_quantized:
        threshold = 0.99
    elif is_fp16:
        threshold = 0.995
    else:
        threshold = 0.999
    print(f"Using {onnx_dir}/{model_file} (quantized={is_quantized}, fp16={is_fp16}, threshold={threshold})")

    print(f"Loading PyTorch reference {HF_MODEL}...")
    t0 = time.time()
    pt_model = SentenceTransformer(HF_MODEL, device="cpu", trust_remote_code=True)
    pt_model.max_seq_length = 256
    print(f"  loaded in {time.time() - t0:.1f}s, dim={pt_model.get_sentence_embedding_dimension()}")

    print(f"\nLoading ONNX {onnx_dir}/{model_file}...")
    t0 = time.time()
    sess_options = ort.SessionOptions()
    disabled_optimizers = []
    if is_fp16:
        # The fp16 converter inserted "InsertedPrecisionFreeCast_*" nodes around
        # LayerNorm subgraphs. ORT's SimplifiedLayerNormFusion can't match the
        # pattern with those casts in the way and fails to load. Disable the
        # specific optimizers that try to fuse LayerNorm.
        sess_options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
        disabled_optimizers = [
            "SimplifiedLayerNormFusion",
            "LayerNormFusion",
            "SkipLayerNormFusion",
            "SkipSimplifiedLayerNormFusion",
        ]
        print(f"  graph_optimization_level=ORT_DISABLE_ALL  disabled={disabled_optimizers}")
    sess = ort.InferenceSession(
        f"{onnx_dir}/{model_file}",
        sess_options=sess_options,
        providers=["CPUExecutionProvider"],
        disabled_optimizers=disabled_optimizers,
    )
    tok = AutoTokenizer.from_pretrained(onnx_dir)
    print(f"  loaded in {time.time() - t0:.1f}s")
    print(f"  ONNX inputs:  {[i.name for i in sess.get_inputs()]}")
    print(f"  ONNX outputs: {[o.name for o in sess.get_outputs()]}")

    # --- PyTorch reference ---
    print(f"\nEncoding {len(TEST_QUERIES)} queries via PyTorch...")
    t0 = time.time()
    pt_vecs = pt_model.encode(TEST_QUERIES, batch_size=8, normalize_embeddings=True)
    print(f"  done in {time.time() - t0:.1f}s, shape={pt_vecs.shape}")

    # --- ONNX inference ---
    print(f"\nEncoding {len(TEST_QUERIES)} queries via ONNX...")
    t0 = time.time()
    enc = tok(TEST_QUERIES, padding=True, truncation=True, max_length=256, return_tensors="np")
    feeds = {
        "input_ids": enc["input_ids"].astype(np.int64),
        "attention_mask": enc["attention_mask"].astype(np.int64),
    }
    # Some ONNX exports also need position_ids
    input_names = {i.name for i in sess.get_inputs()}
    if "position_ids" in input_names:
        T = enc["input_ids"].shape[1]
        feeds["position_ids"] = np.tile(np.arange(T, dtype=np.int64), (len(TEST_QUERIES), 1))

    outputs = sess.run(None, feeds)
    out_names = [o.name for o in sess.get_outputs()]
    out_map = dict(zip(out_names, outputs))

    # Optimum's feature-extraction export for sentence-transformers produces
    # both the raw token_embeddings AND the pooled/normalized sentence_embedding.
    # Prefer the latter so we exactly match the PyTorch reference's pipeline.
    if "sentence_embedding" in out_map:
        onnx_vecs = out_map["sentence_embedding"]
        print(f"  using ONNX sentence_embedding directly: {onnx_vecs.shape}")
    else:
        token_embeds = out_map.get("token_embeddings", out_map.get("last_hidden_state", outputs[0]))
        print(f"  raw token_embeddings shape: {token_embeds.shape}; applying manual mean-pool + normalize")
        pooled = mean_pool(token_embeds, enc["attention_mask"])
        onnx_vecs = l2_normalize(pooled)
    print(f"  ONNX pipeline done, took {time.time() - t0:.1f}s")

    # --- Compare ---
    sims = cosine_sim(pt_vecs, onnx_vecs)
    print(f"\n{'=' * 60}")
    print(f"Cosine similarity (PyTorch vs ONNX) over {len(sims)} queries:")
    print(f"  min:    {sims.min():.6f}")
    print(f"  mean:   {sims.mean():.6f}")
    print(f"  median: {np.median(sims):.6f}")
    print(f"  max:    {sims.max():.6f}")
    print(f"{'=' * 60}")

    if sims.min() > threshold:
        print(f"PASS — all queries above {threshold}")
        return 0
    else:
        n_below = (sims <= threshold).sum()
        print(f"FAIL — {n_below}/{len(sims)} queries below {threshold}")
        # show worst offenders
        worst_idx = sims.argsort()[:5]
        print("  Worst queries:")
        for i in worst_idx:
            print(f"    sim={sims[i]:.6f}  '{TEST_QUERIES[i][:60]}'")
        return 1


if __name__ == "__main__":
    sys.exit(main())
