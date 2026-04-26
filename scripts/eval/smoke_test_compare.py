"""Compare Ruby ONNX output to Python ONNX output for the same queries.

Reads /tmp/ruby_qwen3_vecs.json (produced by smoke_test_qwen3_ruby.rb),
encodes the same queries via Python onnxruntime, computes cosine similarity.
"""
import json
import sys
from pathlib import Path

import numpy as np
import onnxruntime as ort
from transformers import AutoTokenizer

MODEL_DIR = "vendor/models/qwen3_embed_fused_fp16"

def main():
    print(f"Loading Ruby output from /tmp/ruby_qwen3_vecs.json")
    with open("/tmp/ruby_qwen3_vecs.json") as f:
        ruby_data = json.load(f)
    texts = ruby_data["texts"]
    ruby_vecs = np.array(ruby_data["vectors"], dtype=np.float32)
    print(f"  {len(texts)} queries, vec shape {ruby_vecs.shape}")

    print(f"\nLoading Python ONNX from {MODEL_DIR}")
    sess_options = ort.SessionOptions()
    sess_options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
    sess = ort.InferenceSession(
        f"{MODEL_DIR}/model.onnx",
        sess_options=sess_options,
        providers=["CPUExecutionProvider"],
        disabled_optimizers=["SimplifiedLayerNormFusion", "LayerNormFusion",
                             "SkipLayerNormFusion", "SkipSimplifiedLayerNormFusion"],
    )
    tok = AutoTokenizer.from_pretrained(MODEL_DIR)

    enc = tok(texts, padding=True, truncation=True, max_length=256, return_tensors="np")
    feeds = {
        "input_ids": enc["input_ids"].astype(np.int64),
        "attention_mask": enc["attention_mask"].astype(np.int64),
    }
    outputs = sess.run(None, feeds)
    out_map = dict(zip([o.name for o in sess.get_outputs()], outputs))
    py_vecs = out_map["sentence_embedding"].astype(np.float32)
    print(f"  Python vec shape {py_vecs.shape}")

    # Per-row cosine similarity
    print(f"\n{'='*60}")
    print(f"{'idx':>3} {'cosine':>10}  {'text':<60}")
    print(f"{'-'*80}")
    sims = []
    for i, (rv, pv, txt) in enumerate(zip(ruby_vecs, py_vecs, texts)):
        sim = float(np.dot(rv, pv) / (np.linalg.norm(rv) * np.linalg.norm(pv)))
        sims.append(sim)
        print(f"{i:>3} {sim:>10.6f}  {txt[:60]}")
    sims = np.array(sims)
    print(f"{'-'*80}")
    print(f"min: {sims.min():.6f}  mean: {sims.mean():.6f}  max: {sims.max():.6f}")

    threshold = 0.999
    if sims.min() > threshold:
        print(f"\nPASS — Ruby ONNX matches Python ONNX (min cos {sims.min():.4f} > {threshold})")
        return 0
    else:
        print(f"\nFAIL — Ruby ONNX disagrees with Python ONNX (min cos {sims.min():.4f} < {threshold})")
        return 1


if __name__ == "__main__":
    sys.exit(main())
