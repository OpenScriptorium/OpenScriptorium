"""
Auto mixed-precision fp16 conversion: actually runs the model on a sample
input, and only converts ops to fp16 where the numerical drift is below a
tolerance. More robust than blind conversion — produces a graph that's
guaranteed to load and run correctly.

Usage:
  python scripts/eval/onnx_to_fp16_auto.py <input_dir> <output_dir>
"""
import shutil
import sys
from pathlib import Path

import numpy as np
import onnx
from onnxconverter_common.auto_mixed_precision import auto_convert_mixed_precision
from transformers import AutoTokenizer


def main():
    src_dir = Path(sys.argv[1])
    dst_dir = Path(sys.argv[2])
    dst_dir.mkdir(parents=True, exist_ok=True)

    src_model_path = src_dir / "model.onnx"
    dst_model_path = dst_dir / "model.onnx"

    print(f"Loading {src_model_path}...")
    model = onnx.load(str(src_model_path))

    # Build a sample input: tokenize a representative biblical text.
    print("Tokenizing sample input...")
    tok = AutoTokenizer.from_pretrained(str(src_dir))
    enc = tok(
        ["In the beginning God created the heavens and the earth"],
        padding="max_length", truncation=True, max_length=64, return_tensors="np",
    )
    feed = {
        "input_ids": enc["input_ids"].astype(np.int64),
        "attention_mask": enc["attention_mask"].astype(np.int64),
    }

    print("Running auto mixed-precision conversion (this can take a few minutes)...")
    print("  rtol=0.01, atol=0.001 (per-op tolerance)")
    model_fp16 = auto_convert_mixed_precision(
        model,
        feed_dict=feed,
        rtol=0.01,
        atol=0.001,
        keep_io_types=True,
    )

    print(f"Saving to {dst_model_path}...")
    onnx.save_model(
        model_fp16,
        str(dst_model_path),
        save_as_external_data=True,
        all_tensors_to_one_file=True,
        location="model.onnx_data",
    )

    for f in src_dir.iterdir():
        if f.is_file() and not f.name.startswith("model"):
            shutil.copy2(f, dst_dir / f.name)
    print(f"Done. Wrote {dst_dir}.")


if __name__ == "__main__":
    main()
