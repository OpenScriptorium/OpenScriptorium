"""
Encode query strings via an ONNX model (for eval against the production
fp32 corpus). Mirrors scripts/eval/encode_queries.py protocol:

  stdin:  qid<TAB>text
  stdout: qid<TAB>[v1,v2,...]   (pgvector text format, L2-normalized)

Auto-detects model.onnx vs model_quantized.onnx in the given dir.

Usage:
  python encode_queries_onnx.py <onnx_dir>
"""
import os
import sys

import numpy as np
import onnxruntime as ort
from transformers import AutoTokenizer


def main():
    onnx_dir = sys.argv[1]
    candidates = ["model.onnx", "model_quantized.onnx"]
    model_file = next((f for f in candidates if os.path.exists(f"{onnx_dir}/{f}")), None)
    if model_file is None:
        print(f"ERROR: no .onnx file in {onnx_dir}", file=sys.stderr)
        sys.exit(2)

    sys.stderr.write(f"loading {onnx_dir}/{model_file}...\n"); sys.stderr.flush()
    sess = ort.InferenceSession(f"{onnx_dir}/{model_file}", providers=["CPUExecutionProvider"])
    tok  = AutoTokenizer.from_pretrained(onnx_dir)
    sys.stderr.write(f"ready (model_file={model_file})\n"); sys.stderr.flush()

    batch_size = int(os.environ.get("BATCH_SIZE", "16"))
    qids, texts = [], []

    def flush():
        if not qids:
            return
        enc = tok(texts, padding=True, truncation=True, max_length=256, return_tensors="np")
        feeds = {
            "input_ids": enc["input_ids"].astype(np.int64),
            "attention_mask": enc["attention_mask"].astype(np.int64),
        }
        outputs = sess.run(None, feeds)
        out_names = [o.name for o in sess.get_outputs()]
        out_map = dict(zip(out_names, outputs))
        # Optimum's feature-extraction export gives us pooled+normalized
        # sentence_embedding directly — exactly matches the corpus encoding.
        if "sentence_embedding" in out_map:
            vecs = out_map["sentence_embedding"]
        else:
            tok_emb = out_map.get("token_embeddings", outputs[0])
            mask = enc["attention_mask"][..., None].astype(np.float32)
            pooled = (tok_emb * mask).sum(axis=1) / mask.sum(axis=1).clip(min=1e-9)
            norm = np.linalg.norm(pooled, axis=-1, keepdims=True).clip(min=1e-12)
            vecs = pooled / norm

        out = sys.stdout
        for qid, vec in zip(qids, vecs.tolist()):
            out.write(qid)
            out.write("\t[")
            out.write(",".join(f"{v:.6f}" for v in vec))
            out.write("]\n")
        out.flush()
        qids.clear(); texts.clear()

    for line in sys.stdin:
        line = line.rstrip("\n")
        sep = line.find("\t")
        if sep < 0:
            continue
        qids.append(line[:sep])
        texts.append(line[sep + 1:])
        if len(qids) >= batch_size:
            flush()
    flush()


if __name__ == "__main__":
    main()
