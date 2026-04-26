"""
Encode query strings for retrieval eval.

Reads `qid<TAB>text` lines from stdin, writes `qid<TAB>[v1,v2,...]` to stdout.
The vector format is the literal pgvector text representation so it can be
fed straight into a SQL `<=>` operator.

Usage:
    python encode_queries.py <model_path_or_id> [device] [--prompt PROMPT_NAME] [--dim N]

Args:
    model_path_or_id  HF model id or local path
    device            mps | cuda | cpu (default: mps)
    --prompt NAME     prompt key from the model's prompts.json
                      (e.g. 'query' for instruction-tuned Qwen3-Embedding)
    --dim N           truncate output to first N dims (Matryoshka)
"""
import argparse
import os
import sys

from sentence_transformers import SentenceTransformer


def main():
    p = argparse.ArgumentParser()
    p.add_argument("model_path")
    p.add_argument("device", nargs="?", default=os.environ.get("DEVICE", "mps"))
    p.add_argument("--prompt", default=None, help="prompt_name from prompts.json")
    p.add_argument("--dim", type=int, default=0, help="truncate to first N dims")
    args = p.parse_args()

    batch_size = int(os.environ.get("BATCH_SIZE", "64"))

    model = SentenceTransformer(args.model_path, device=args.device, trust_remote_code=True)
    sys.stderr.write(
        f"ready (device={model.device}, native_dim={model.get_sentence_embedding_dimension()}, "
        f"prompt={args.prompt or 'none'})\n"
    )
    sys.stderr.flush()

    qids, texts = [], []

    encode_kwargs = {"batch_size": batch_size, "show_progress_bar": False}
    if args.prompt:
        encode_kwargs["prompt_name"] = args.prompt

    def flush():
        if not qids:
            return
        vecs = model.encode(texts, **encode_kwargs)
        if args.dim and args.dim < vecs.shape[1]:
            vecs = vecs[:, :args.dim]
        vecs = vecs.tolist()
        out = sys.stdout
        for qid, vec in zip(qids, vecs):
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
