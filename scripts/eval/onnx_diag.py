"""Print a focused dump of the offending node and its consumers."""
import sys
import onnx
from onnx import TensorProto

TT = {v: k for k, v in TensorProto.DataType.items()}

model = onnx.load(sys.argv[1])
g = model.graph

target_node_name = "/0/layers.0/input_layernorm/Cast_1"
target_output = "InsertedPrecisionFreeCast_/0/layers.0/input_layernorm/Cast_1_output_0"

# Find target node
node = next((n for n in g.node if n.name == target_node_name), None)
print(f"target node: {target_node_name}")
if node is None:
    print("  NOT FOUND in graph; searching by similar name...")
    for n in g.node:
        if "Cast_1" in n.name and "input_layernorm" in n.name:
            print(f"  candidate: {n.name}  op={n.op_type}  outputs={list(n.output)}")
else:
    print(f"  op_type: {node.op_type}")
    print(f"  inputs:  {list(node.input)}")
    print(f"  outputs: {list(node.output)}")
    print(f"  attrs:   {[(a.name, a.i if a.type == 2 else a.s if a.type == 3 else '?') for a in node.attribute]}")

# Find any node that outputs the problematic name
for n in g.node:
    if target_output in n.output:
        print(f"\nactual producer of {target_output}:")
        print(f"  name: {n.name}")
        print(f"  op_type: {n.op_type}")
        print(f"  inputs:  {list(n.input)}")
        print(f"  outputs: {list(n.output)}")
        print(f"  attrs:   {[(a.name, a.i if a.type == 2 else a.s if a.type == 3 else '?') for a in n.attribute]}")

# Look up value_info for the target output name
vi = next((v for v in list(g.value_info) + list(g.input) + list(g.output) if v.name == target_output), None)
if vi is None:
    print(f"\nNo value_info entry for {target_output}")
else:
    print(f"\nvalue_info[{target_output}]: elem_type = {TT.get(vi.type.tensor_type.elem_type)}")

# Find consumers of the target output
print(f"\nconsumers of {target_output}:")
for n in g.node:
    if target_output in n.input:
        print(f"  {n.name} ({n.op_type})  inputs={list(n.input)}")
