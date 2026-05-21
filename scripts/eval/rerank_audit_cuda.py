"""Score (query, doc) pairs with Qwen3-Reranker-0.6B fp16 ONNX on CUDA.

Pass-2 of the two-pass audit. Reads JSONL produced by `eval:thematic
RERANK_INPUT_OUT=...` and writes JSONL with rerank scores per (qid, rid),
formatted for `eval:thematic RERANK_SCORES_IN=...` to ingest.

Designed to run on a separate GPU box that does not have the rails app
or DB. Same fp16 ONNX file as production; same prompt template and
yes/no-logit-diff scoring as `Search::Reranker` in app/services/.

Input format (one JSON object per line):
  {"qid": "c123_name", "query": "throne of God", "candidates": [
     {"rid": 12345, "body": "And immediately I was in the spirit..."},
     ...
  ]}

Output format (one JSON object per line):
  {"qid": "c123_name", "scores": {"12345": 4.91, "12346": 1.23, ...}}

Usage:
  python rerank_audit_cuda.py \
    --input  rerank_input.jsonl \
    --output rerank_output.jsonl \
    --model-dir vendor/models/qwen3_rerank_fused_fp16 \
    [--batch-size 8] [--max-len 384]
"""
import argparse
import glob
import json
import os
import sys
import time


def _bootstrap_cuda_libs():
    """If onnxruntime-gpu is installed in a venv with pip-installed nvidia-*
    runtime wheels, prepend their lib dirs to LD_LIBRARY_PATH and re-exec.
    This avoids requiring the user to set LD_LIBRARY_PATH by hand."""
    if os.environ.get("_RERANK_CUDA_BOOTSTRAPPED") == "1":
        return
    candidates = []
    for sp in sys.path:
        nv = os.path.join(sp, "nvidia")
        if os.path.isdir(nv):
            candidates.extend(sorted(glob.glob(os.path.join(nv, "*", "lib"))))
    if not candidates:
        return
    new_ld = ":".join(candidates + [os.environ.get("LD_LIBRARY_PATH", "")])
    os.environ["LD_LIBRARY_PATH"] = new_ld
    os.environ["_RERANK_CUDA_BOOTSTRAPPED"] = "1"
    os.execv(sys.executable, [sys.executable] + sys.argv)


_bootstrap_cuda_libs()

import numpy as np
import onnxruntime as ort
from transformers import AutoTokenizer


SYSTEM_MSG = (
    'Judge whether the Document meets the requirements based on the Query '
    'and the Instruct provided. Note that the answer can only be "yes" or "no".'
)

# Match Search::Reranker::DEFAULT_INSTRUCT in app/services/search/reranker.rb.
DEFAULT_INSTRUCT = (
    "Given a search query, retrieve passages of Scripture or biblical text "
    "that match the query's meaning and intent."
)

YES_TOKEN_ID = 9693
NO_TOKEN_ID  = 2152

# Match Search::Reranker truncation policy so scores match prod inference.
MAX_DOC_CHARS = 600
MAX_QUERY_CHARS = 200


def build_prompt(query, doc, instruct=DEFAULT_INSTRUCT):
    return (
        f"<|im_start|>system\n{SYSTEM_MSG}<|im_end|>\n"
        f"<|im_start|>user\n"
        f"<Instruct>: {instruct}\n"
        f"<Query>: {query}\n"
        f"<Document>: {doc}<|im_end|>\n"
        f"<|im_start|>assistant\n"
        f"<think>\n\n</think>\n\n"
    )


def score_batch(sess, tok, prompts, pad_id, max_len):
    """Score a batch of prompts. Returns list of float scores."""
    encs = tok(prompts, padding=True, truncation=True, max_length=max_len,
               return_tensors="np", add_special_tokens=False)
    ids = encs["input_ids"].astype(np.int64)
    mask = encs["attention_mask"].astype(np.int64)
    seq = ids.shape[1]
    pos = np.broadcast_to(np.arange(seq, dtype=np.int64), ids.shape).copy()

    out = sess.run(None, {
        "input_ids": ids,
        "attention_mask": mask,
        "position_ids": pos,
    })
    logits = out[0]  # [batch, seq, vocab]

    # For each row, the last *real* token is at (mask.sum(1) - 1).
    # Score = raw_logit(YES) - raw_logit(NO). The log-softmax denominator
    # cancels in same-row subtraction, so raw logits are fine.
    scores = []
    for i in range(logits.shape[0]):
        last_real = int(mask[i].sum()) - 1
        row = logits[i, last_real, :]
        scores.append(float(row[YES_TOKEN_ID] - row[NO_TOKEN_ID]))
    return scores


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--model-dir", required=True)
    ap.add_argument("--batch-size", type=int, default=8)
    ap.add_argument("--max-len", type=int, default=384)
    ap.add_argument("--instruct", default=DEFAULT_INSTRUCT)
    ap.add_argument("--provider", default="cuda",
                    choices=["cuda", "cpu"], help="Execution provider")
    args = ap.parse_args()

    onnx_path = os.path.join(args.model_dir, "model.onnx")
    if not os.path.exists(onnx_path):
        print(f"ERROR: {onnx_path} not found", file=sys.stderr)
        return 2

    print(f"Loading tokenizer from {args.model_dir}...", flush=True)
    tok = AutoTokenizer.from_pretrained(args.model_dir)
    pad_id = tok.convert_tokens_to_ids("<|endoftext|>")
    if pad_id is None or pad_id == tok.unk_token_id:
        pad_id = 0
    print(f"  pad_id={pad_id}  yes={YES_TOKEN_ID}  no={NO_TOKEN_ID}", flush=True)

    providers = {
        "cuda": ["CUDAExecutionProvider", "CPUExecutionProvider"],
        "cpu":  ["CPUExecutionProvider"],
    }[args.provider]
    print(f"Loading ONNX session ({args.provider})...", flush=True)
    sess = ort.InferenceSession(onnx_path, providers=providers)
    print(f"  active providers: {sess.get_providers()}", flush=True)
    if args.provider == "cuda" and "CUDAExecutionProvider" not in sess.get_providers():
        print("  WARNING: CUDA EP not active — falling back to CPU. "
              "Install onnxruntime-gpu and verify GPU drivers.", file=sys.stderr)

    # Read all input rows. Each is one query with N candidates → N pairs.
    rows = []
    with open(args.input) as f:
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            rows.append(json.loads(ln))

    total_pairs = sum(len(r["candidates"]) for r in rows)
    print(f"Loaded {len(rows)} queries, {total_pairs} (query, doc) pairs", flush=True)
    print(f"Batch size: {args.batch_size}  Max seq len: {args.max_len}", flush=True)

    # Process in two layers: per-query, then within-query batched. We keep
    # output ordered by qid in the same order as input so resumption (if we
    # ever add it) is trivial.
    t0 = time.time()
    n_pairs_done = 0
    with open(args.output, "w") as out_f:
        for ri, row in enumerate(rows):
            qid = row["qid"]
            query = row["query"][:MAX_QUERY_CHARS]
            cands = row["candidates"]
            scores = {}
            for j in range(0, len(cands), args.batch_size):
                slice_ = cands[j:j + args.batch_size]
                prompts = [build_prompt(query, c["body"][:MAX_DOC_CHARS], args.instruct)
                           for c in slice_]
                batch_scores = score_batch(sess, tok, prompts, pad_id, args.max_len)
                for c, s in zip(slice_, batch_scores):
                    scores[str(c["rid"])] = s
                n_pairs_done += len(slice_)
            out_f.write(json.dumps({"qid": qid, "scores": scores}) + "\n")
            out_f.flush()

            if (ri + 1) % 10 == 0 or ri == len(rows) - 1:
                elapsed = time.time() - t0
                rate = n_pairs_done / max(elapsed, 1e-3)
                eta = (total_pairs - n_pairs_done) / max(rate, 1e-3)
                print(f"  q={ri + 1}/{len(rows)}  pairs={n_pairs_done}/{total_pairs}  "
                      f"{rate:.1f} pair/s  elapsed={elapsed:.0f}s  eta={eta:.0f}s",
                      flush=True)

    elapsed = time.time() - t0
    print(f"Done. {n_pairs_done} pairs in {elapsed:.1f}s "
          f"({n_pairs_done/elapsed:.1f} pair/s, "
          f"{1000*elapsed/n_pairs_done:.1f} ms/pair)", flush=True)
    print(f"Wrote {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
