"""
Convert an ONNX model from fp32 to fp16 in-place.

Tries onnxruntime's transformer-aware converter first (handles LayerNorm
type mismatches that the generic onnxconverter-common path misses), falls
back to the generic converter if not available.

Usage:
  python scripts/eval/onnx_to_fp16.py <input_dir> <output_dir>
"""
import shutil
import sys
from pathlib import Path

import onnx


def main():
    src_dir = Path(sys.argv[1])
    dst_dir = Path(sys.argv[2])
    dst_dir.mkdir(parents=True, exist_ok=True)

    src_model_path = src_dir / "model.onnx"
    dst_model_path = dst_dir / "model.onnx"

    print(f"Loading {src_model_path}...")
    model = onnx.load(str(src_model_path))
    print(f"  ops: {len(model.graph.node)}, initializers: {len(model.graph.initializer)}")

    print("Converting fp32 → fp16 with transformer-aware converter...")
    try:
        # Newer onnxruntime exposes float16 conversion for transformers via
        # onnxruntime.transformers.float16. It inserts Cast nodes correctly
        # at fp32/fp16 boundaries so LayerNorm and similar nodes don't break.
        from onnxruntime.transformers.float16 import convert_float_to_float16
        model_fp16 = convert_float_to_float16(
            model,
            keep_io_types=True,
            op_block_list=["LayerNormalization", "SimplifiedLayerNormalization", "SkipLayerNormalization"],
            disable_shape_infer=True,
        )
        print("  used onnxruntime.transformers converter")
    except ImportError:
        from onnxconverter_common import float16
        model_fp16 = float16.convert_float_to_float16(
            model,
            keep_io_types=True,
            disable_shape_infer=True,
        )
        print("  used onnxconverter-common converter (fallback)")

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
