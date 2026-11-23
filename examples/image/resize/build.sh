#!/bin/sh
# examples/image/resize -- from the declarations (kernels.rb) to .vmfb files and a single binary.
#
#   ./build.sh      → build/{app, resize_cpu.vmfb, resize_metal.vmfb}
#   ./run.sh        -> the 3 shrinks on both devices
#
# Requires: the IREE runtime and iree-compile (see examples/image/README.md).
#
# Unlike filter/, there is **one** .mlir. These declarations have no `border:`,
# and therefore no `pad_via:` either, so there is nothing to branch on per device
# profile. There are 2 .vmfb files because it is compiled for 2 backends; to the
# generator it is one and the same module.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../env.sh"

OUT=$HERE/build
rm -rf "$OUT"
mkdir -p "$OUT/spinel"

echo "== images (shared: $IMG) =="
mkimages

cp "$SURFACE" "$OUT/spinel/"
cp "$HERE/kernels.rb" "$HERE/app.rb" "$OUT/"

echo "== spinel-mlirgen --tensor =="
(cd "$OUT" && "$MLIRGEN" kernels.rb --tensor \
    -o resize.mlir \
    --emit-table sp_tensor_table.h \
    --emit-ruby kernels.gen.rb \
    --iree-compile "$IREE_COMPILE" --vmfb resize)

echo "== shim + f32 reference + spinel =="
"$CC" -O2 -c "$SHIM" -o "$OUT/sp_tensor_shim.o" $IREE_CFLAGS -I"$OUT"
# -ffp-contract=off: if the reference contracted to FMA on its own, enumerating the 3 ways would mean nothing.
"$CC" -O2 -ffp-contract=off -c "$HERE/ref.c" -o "$OUT/ref.o"
(cd "$OUT" && "$SPINEL" app.rb -o app \
    --link "$OUT/sp_tensor_shim.o" --link "$OUT/ref.o" $IREE_LINK)

ls -la "$OUT/app" "$OUT"/resize_*.vmfb
echo "resize: built. next: $HERE/run.sh"
