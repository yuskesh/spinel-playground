#!/bin/sh
# examples/image/filter -- from the declarations (kernels.rb) to .vmfb files and a single binary.
#
#   ./build.sh      -> build/{app, filter_cpu.vmfb, filter_metal.vmfb} and the 4K images
#   ./run.sh        -> runs both devices x 2 tails and prints the table
#
# Requires: the IREE runtime and iree-compile (see examples/image/README.md).
#
# The generator writes **2** .mlir files, because `pad_via: :auto` chooses the boundary's
# lowering per device profile, so filter.cpu.mlir and filter.metal.mlir are
# different texts. **That the table (sp_tensor_table.h) and .gen.rb match byte for byte
# across the profiles** is checked by the generator itself: a lowering that reaches the ABI
# is semantics, not a choice of speed.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../env.sh"

OUT=$HERE/build
rm -rf "$OUT"
mkdir -p "$OUT/spinel"

echo "== images (shared: $IMG) =="
mkimages

# The surface (tensor.rb) comes from tools/tensor. The sample keeps no copy of its own.
cp "$SURFACE" "$OUT/spinel/"
cp "$HERE/kernels.rb" "$HERE/app.rb" "$OUT/"

# --- 1. the generator: 4 declarations -> .mlir x2 -> .vmfb x2 + the table + dispatch defs ---
echo "== spinel-mlirgen --tensor (W4: 2 device profiles) =="
(cd "$OUT" && "$MLIRGEN" kernels.rb --tensor \
    -o filter.mlir \
    --emit-table sp_tensor_table.h \
    --emit-ruby kernels.gen.rb \
    --iree-compile "$IREE_COMPILE" --vmfb filter)

# --- 2. shim + reference implementation + program ---------------------------------
# -I the same place as the table (sp_tensor_table.h): the shim's dispatch reads that table.
echo "== shim + f32 reference + spinel =="
"$CC" -O2 -c "$SHIM" -o "$OUT/sp_tensor_shim.o" $IREE_CFLAGS -I"$OUT"
# -ffp-contract=off: the reference decides its own rounding. With a reference that the host
# compiler contracted into FMA on its own, "did the device contract?" cannot be asked.
"$CC" -O2 -ffp-contract=off -c "$HERE/ref.c" -o "$OUT/ref.o"
(cd "$OUT" && "$SPINEL" app.rb -o app \
    --link "$OUT/sp_tensor_shim.o" --link "$OUT/ref.o" $IREE_LINK)

ls -la "$OUT/app" "$OUT"/filter_*.vmfb
echo "filter: built. next: $HERE/run.sh"
