#!/bin/sh
# examples/tensor/fusion -- runs the generator **twice**. The reason is the surface's shape, not chance.
#
#   pass 1  reads only the kernel file (tensor_def) and writes kernels.gen.rb, which the
#           program require_relatives. Without it `k_mul(...)` is an undefined method,
#           and app.rb does not even parse.
#   pass 2  reads the kernel file **and**, with --fuse, the program. It compiles app.rb's
#           `dest.assign!(expr)` statements into the same module and writes app.fused.rb,
#           with each statement rewritten into a call to a generated dispatch.
#           **What is compiled is app.fused.rb.**
#
#   ./build.sh      → build/{app, fusion_cpu.vmfb, fusion_metal.vmfb, app.fused.rb}
#   ./run.sh        -> runs on both devices and prints the table
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../env.sh"

OUT=$HERE/build
rm -rf "$OUT"
mkdir -p "$OUT/spinel"
cp "$SURFACE" "$OUT/spinel/"
cp "$HERE/kernels.rb" "$HERE/app.rb" "$OUT/"

echo "== pass 1: tensor_def only =="
(cd "$OUT" && "$MLIRGEN" kernels.rb --tensor \
    -o pass1.mlir --emit-table pass1_table.h --emit-ruby kernels.gen.rb)

echo "== pass 2: --fuse app.rb =="
(cd "$OUT" && "$MLIRGEN" kernels.rb --tensor \
    --fuse app.rb --emit-fused app.fused.rb \
    -o fusion.mlir \
    --emit-table sp_tensor_table.h \
    --emit-ruby kernels.gen.rb \
    --iree-compile "$IREE_COMPILE" --vmfb fusion)

# The whole rewrite. Outside the fused statements not one byte has moved.
(cd "$OUT" && diff -u app.rb app.fused.rb > rewrite.diff || true)
echo "== the rewrite (build/rewrite.diff) =="
cat "$OUT/rewrite.diff"

echo "== shim + spinel =="
"$CC" -O2 -c "$SHIM" -o "$OUT/sp_tensor_shim.o" $IREE_CFLAGS -I"$OUT"
#                                              v not the app.rb you wrote
(cd "$OUT" && "$SPINEL" app.fused.rb -o app --link "$OUT/sp_tensor_shim.o" $IREE_LINK)

ls -la "$OUT/app" "$OUT"/fusion_*.vmfb
echo "fusion: built. next: $HERE/run.sh"
