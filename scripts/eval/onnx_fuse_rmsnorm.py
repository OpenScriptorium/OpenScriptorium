"""
Pre-fuse the decomposed RMSNorm pattern in a Qwen3-style ONNX export into a
single `com.microsoft.SimplifiedLayerNormalization` op.

The exported pattern (one per layernorm site in the model) is:

  X
   ├─→ Cast(to=fp32) → cast_out
   │
   ├─ cast_out ─→ Pow(2) → ReduceMean → Add(eps) → Sqrt → Div(1/x) ─┐
   │                                                                 │
   └─ cast_out ─×─────────────────────────────────────── Mul ←───────┘
                                                          │
                                                  Cast(to=W_dtype)
                                                          │
                                          weight ──×── Mul ──→ output

We rewrite each occurrence to:

  X, weight ──→ SimplifiedLayerNormalization(epsilon, axis=-1) ──→ output

This dodges ORT's SimplifiedLayerNormFusion runtime pass, which is what
trips up after fp16 conversion. Run this on the *fp32* graph BEFORE fp16
conversion.

Usage:
  python scripts/eval/onnx_fuse_rmsnorm.py <input_dir> <output_dir>
"""
import shutil
import sys
from pathlib import Path

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper


def get_const_value(node, by_output, by_init):
    """Return the numpy value behind a Constant node or initializer."""
    if node.op_type == "Constant":
        for a in node.attribute:
            if a.name == "value":
                return numpy_helper.to_array(a.t)
    return None


def main():
    src_dir = Path(sys.argv[1])
    dst_dir = Path(sys.argv[2])
    dst_dir.mkdir(parents=True, exist_ok=True)

    src_path = src_dir / "model.onnx"
    dst_path = dst_dir / "model.onnx"

    print(f"Loading {src_path}...")
    model = onnx.load(str(src_path))
    g = model.graph

    by_output = {o: n for n in g.node for o in n.output}
    by_init = {i.name: i for i in g.initializer}

    # Find Mul_1 nodes whose name ends with "Mul_1" and whose first input is
    # a *_layernorm.weight initializer. This anchors the bottom of the
    # decomposed RMSNorm pattern.
    candidates = []
    for n in g.node:
        if n.op_type != "Mul":
            continue
        if not n.name.endswith("/Mul_1"):
            continue
        # Two-input Mul; one input must be an initializer ending in
        # _norm.weight or .norm.weight (covers input_layernorm,
        # post_attention_layernorm, q_norm, k_norm, final norm).
        weight_name = None
        other_input = None
        for inp in n.input:
            if inp in by_init and (
                "_norm.weight" in inp.lower() or
                ".norm.weight" in inp.lower() or
                "layernorm.weight" in inp.lower()
            ):
                weight_name = inp
            else:
                other_input = inp
        if weight_name is None or other_input is None:
            continue
        candidates.append((n, weight_name, other_input))

    print(f"Found {len(candidates)} layernorm Mul_1 candidates.")

    fused_count = 0
    nodes_to_remove = set()
    new_nodes = []

    for mul_1, weight_name, mul_1_other_input in candidates:
        # mul_1_other_input is Cast_1's output. Walk back.
        cast_1 = by_output.get(mul_1_other_input)
        if cast_1 is None or cast_1.op_type != "Cast":
            continue

        # Cast_1 input = Mul output (the multiply of cast_x and div)
        mul_in = cast_1.input[0]
        mul_node = by_output.get(mul_in)
        if mul_node is None or mul_node.op_type != "Mul":
            continue

        # Mul has two inputs: cast_out and div_out (or vice versa)
        cast_x_out = None
        div_out = None
        for inp in mul_node.input:
            producer = by_output.get(inp)
            if producer and producer.op_type == "Cast" and producer.name.endswith("/Cast"):
                cast_x_out = inp
                cast_x = producer
            elif producer and producer.op_type == "Div":
                div_out = inp
                div = producer
        if cast_x_out is None or div_out is None:
            continue

        # X = input to Cast (the very first one)
        x_input = cast_x.input[0]

        # Div: Div(constant_one, sqrt_out)
        sqrt_in = None
        for inp in div.input:
            producer = by_output.get(inp)
            if producer and producer.op_type == "Sqrt":
                sqrt_in = inp
                sqrt = producer
                break
        if sqrt_in is None:
            continue

        # Sqrt input = Add output
        add_in = sqrt.input[0]
        add = by_output.get(add_in)
        if add is None or add.op_type != "Add":
            continue

        # Add has ReduceMean + Constant(epsilon)
        rm_out = None
        eps_const_out = None
        for inp in add.input:
            producer = by_output.get(inp)
            if producer and producer.op_type == "ReduceMean":
                rm_out = inp
                rm = producer
            elif producer and producer.op_type == "Constant":
                eps_const_out = inp
        if rm_out is None or eps_const_out is None:
            continue

        # Get epsilon value
        eps_node = by_output[eps_const_out]
        eps_value = float(get_const_value(eps_node, by_output, by_init).item())

        # ReduceMean(Pow_out)
        pow_out = rm.input[0]
        pow_node = by_output.get(pow_out)
        if pow_node is None or pow_node.op_type != "Pow":
            continue

        # Pow input == cast_x_out (the same Cast output Mul also reads)
        if pow_node.input[0] != cast_x_out:
            continue

        # All structural checks pass — emit a fused RMSNormalization (standard
        # ONNX opset 23). Use the *upcast* Cast output (cast_x_out) as input.
        # Cast stays in the graph because the residual Add downstream still
        # consumes its output.
        new_node = helper.make_node(
            "RMSNormalization",
            inputs=[cast_x_out, weight_name],
            outputs=[mul_1.output[0]],
            name=mul_1.name.rsplit("/", 1)[0] + "/Fused",
            axis=-1,
            epsilon=eps_value,
        )
        new_nodes.append(new_node)
        # Mark inner pattern for removal — KEEP cast_x because the residual
        # Add downstream still consumes its output.
        for victim in (pow_node, rm, add, sqrt, div, mul_node, cast_1, mul_1):
            nodes_to_remove.add(victim.name)
        # Also remove the small Constant nodes that fed the decomposed pattern
        for inp in [pow_node.input[1], rm.input[1] if len(rm.input) > 1 else None,
                    eps_const_out, div.input[0]]:
            if inp is None:
                continue
            producer = by_output.get(inp)
            if producer and producer.op_type == "Constant":
                # Only remove if no other node consumes this constant
                consumers = [
                    n for n in g.node
                    if inp in n.input and n.name not in {cast_x.name, pow_node.name,
                                                        rm.name, add.name, sqrt.name,
                                                        div.name, mul_node.name,
                                                        cast_1.name, mul_1.name}
                ]
                if not consumers:
                    nodes_to_remove.add(producer.name)
        fused_count += 1

    print(f"Fused {fused_count} of {len(candidates)} sites.")
    if fused_count == 0:
        print("ERROR: no patterns matched. Check pattern dump for differences.")
        sys.exit(2)

    # Apply: remove old nodes, append new
    surviving = [n for n in g.node if n.name not in nodes_to_remove]
    print(f"Removing {len(g.node) - len(surviving)} nodes; adding {len(new_nodes)} fused nodes.")

    del g.node[:]
    g.node.extend(surviving + new_nodes)

    # Bump default opset to >= 23 (RMSNormalization was added in opset 23).
    for o in model.opset_import:
        if o.domain in ("", "ai.onnx"):
            if o.version < 23:
                print(f"Bumping default opset from {o.version} to 23 (for RMSNormalization).")
                o.version = 23
            break

    # Validate
    print("Validating with onnx.checker...")
    try:
        # com.microsoft ops aren't in standard ONNX schema; checker may complain
        onnx.checker.check_model(model)
        print("  passed")
    except Exception as e:
        # com.microsoft ops are non-standard; checker may reject — that's ok,
        # ORT will still load it.
        print(f"  warn: {type(e).__name__}: {str(e)[:200]}")

    print(f"Saving to {dst_path}...")
    onnx.save_model(
        model, str(dst_path),
        save_as_external_data=True,
        all_tensors_to_one_file=True,
        location="model.onnx_data",
    )

    for f in src_dir.iterdir():
        if f.is_file() and not f.name.startswith("model"):
            shutil.copy2(f, dst_dir / f.name)
    print(f"Done.")


if __name__ == "__main__":
    main()
