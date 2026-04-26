"""
Fix Cast node output value_info entries to match the Cast's 'to' attribute.

The fp16 converter (onnxruntime.transformers.float16) sometimes inserts Cast
nodes whose declared output type in `value_info` doesn't match what the Cast
actually outputs. ORT then errors at session-load with messages like:

  Type Error: Type (tensor(float)) of output arg ... does not match expected
  type (tensor(float16)) for node /0/layers.0/input_layernorm/Cast_1

This script walks every Cast node, looks up the corresponding `value_info`
entry by output name, and rewrites the elem_type to match the Cast's `to`.
Also runs shape inference at the end to validate.

Usage:
  python scripts/eval/onnx_fix_cast_types.py <input_onnx_dir> <output_onnx_dir>
"""
import shutil
import sys
from pathlib import Path

import onnx
from onnx import TensorProto


TENSOR_TYPE_NAMES = {
    TensorProto.FLOAT: "float32",
    TensorProto.FLOAT16: "float16",
    TensorProto.BFLOAT16: "bfloat16",
    TensorProto.INT64: "int64",
    TensorProto.INT32: "int32",
    TensorProto.BOOL: "bool",
}


def main():
    src_dir = Path(sys.argv[1])
    dst_dir = Path(sys.argv[2])
    dst_dir.mkdir(parents=True, exist_ok=True)

    src_model_path = src_dir / "model.onnx"
    dst_model_path = dst_dir / "model.onnx"

    print(f"Loading {src_model_path}...")
    model = onnx.load(str(src_model_path))
    g = model.graph

    # Map value_name -> value_info (covers graph inputs, outputs, and intermediates)
    vi_by_name = {}
    for vi in list(g.value_info) + list(g.input) + list(g.output):
        vi_by_name[vi.name] = vi

    cast_count = 0
    fixed = 0
    mismatches = []

    for node in g.node:
        if node.op_type != "Cast":
            continue
        cast_count += 1
        to_type = None
        for attr in node.attribute:
            if attr.name == "to":
                to_type = attr.i
                break
        if to_type is None:
            continue

        output_name = node.output[0]
        vi = vi_by_name.get(output_name)
        if vi is None:
            continue
        declared = vi.type.tensor_type.elem_type
        if declared != to_type:
            mismatches.append((
                node.name or output_name,
                TENSOR_TYPE_NAMES.get(declared, str(declared)),
                TENSOR_TYPE_NAMES.get(to_type, str(to_type)),
            ))
            vi.type.tensor_type.elem_type = to_type
            fixed += 1

    print(f"\nWalked {cast_count} Cast nodes; fixed {fixed} type mismatches.")
    if mismatches:
        print("Examples (first 10):")
        for name, declared, fixed_to in mismatches[:10]:
            print(f"  {name}: value_info was {declared} → {fixed_to}")

    print("\nRunning shape inference for sanity...")
    try:
        # data_prop=True propagates types through the graph
        model = onnx.shape_inference.infer_shapes(model, data_prop=True)
        print("  shape inference passed")
    except Exception as e:
        print(f"  shape inference warning: {type(e).__name__}: {e}")

    print(f"\nSaving to {dst_model_path}...")
    onnx.save_model(
        model,
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
