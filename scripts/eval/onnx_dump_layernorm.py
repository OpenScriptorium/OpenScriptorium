"""Dump the decomposed LayerNorm subgraph for one layer so we can see the
exact node pattern to fuse.

Usage: python scripts/eval/onnx_dump_layernorm.py <onnx_path> <layer_path_prefix>
   e.g. python scripts/eval/onnx_dump_layernorm.py vendor/models/qwen3_embed/model.onnx /0/layers.0/input_layernorm
"""
import sys
import onnx
from onnx import TensorProto

TT = {v: k for k, v in TensorProto.DataType.items()}


def fmt_attr(a):
    if a.type == 2:
        return f"{a.name}={a.i}"
    if a.type == 3:
        return f"{a.name}={a.s.decode() if isinstance(a.s, bytes) else a.s}"
    if a.type == 1:
        return f"{a.name}={a.f}"
    return f"{a.name}=?"


def main():
    onnx_path = sys.argv[1]
    prefix = sys.argv[2]

    g = onnx.load(onnx_path).graph
    nodes = [n for n in g.node if n.name.startswith(prefix)]
    print(f"Found {len(nodes)} nodes under {prefix}\n")

    # Build name → node lookup for tracing
    by_output = {}
    for n in g.node:
        for o in n.output:
            by_output[o] = n

    # Type lookup
    type_by_name = {}
    for vi in list(g.value_info) + list(g.input) + list(g.output):
        type_by_name[vi.name] = TT.get(vi.type.tensor_type.elem_type, "?")
    for ini in g.initializer:
        type_by_name[ini.name] = TT.get(ini.data_type, "?") + " (init)"

    for n in sorted(nodes, key=lambda x: x.name):
        attrs = ", ".join(fmt_attr(a) for a in n.attribute)
        ins = ", ".join(f"{i}({type_by_name.get(i, '?')})" for i in n.input)
        outs = ", ".join(f"{o}({type_by_name.get(o, '?')})" for o in n.output)
        print(f"{n.name}")
        print(f"  op: {n.op_type}  attrs: {attrs}")
        print(f"  in:  {ins}")
        print(f"  out: {outs}")
        print()


if __name__ == "__main__":
    main()
