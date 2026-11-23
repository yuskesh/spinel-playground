#!/bin/sh
# examples/tensor/dense-relu -- from the declarations (kernels.rb) to .vmfb files and a single binary.
#
#   ./build.sh      → build/{app, dense_relu_cpu.vmfb, dense_relu_metal.vmfb}
#   ./run.sh        -> runs on both devices and prints the table
#
# Requires: the IREE runtime and iree-compile (see examples/tensor/README.md).
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../env.sh"

OUT=$HERE/build
rm -rf "$OUT"
mkdir -p "$OUT/spinel"

# The surface (tensor.rb) comes from tools/tensor. The sample keeps no copy of its own.
cp "$SURFACE" "$OUT/spinel/"
cp "$HERE/kernels.rb" "$HERE/app.rb" "$OUT/"

# --- 1. the generator: 3 declarations -> .mlir -> .vmfb x2 + the table + dispatch defs ---
# Given --vmfb, it calls iree-compile for both llvm-cpu and metal-spirv.
echo "== spinel-mlirgen --tensor =="
(cd "$OUT" && "$MLIRGEN" kernels.rb --tensor \
    -o dense_relu.mlir \
    --emit-table sp_tensor_table.h \
    --emit-ruby kernels.gen.rb \
    --iree-compile "$IREE_COMPILE" --vmfb dense_relu)

# --- 2. shim + program -------------------------------------------------------------
# -I the same place as the table (sp_tensor_table.h): the shim's dispatch reads that table.
echo "== shim + spinel =="
"$CC" -O2 -c "$SHIM" -o "$OUT/sp_tensor_shim.o" $IREE_CFLAGS -I"$OUT"
(cd "$OUT" && "$SPINEL" app.rb -o app --link "$OUT/sp_tensor_shim.o" $IREE_LINK)

ls -la "$OUT/app" "$OUT"/dense_relu_*.vmfb
echo "dense-relu: built. next: $HERE/run.sh"
