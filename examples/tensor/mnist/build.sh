#!/bin/sh
# examples/tensor/mnist -- 2 StableHLO modules -> .vmfb -> a single binary.
#
#   ./build.sh      → build/{app, mnist_mlp_{cpu,metal}.vmfb, mnist_scale_{cpu,metal}.vmfb}
#   ./run.sh        -> fetches MNIST and classifies it on both devices
#
# The asymmetry is this script's very shape: the input model/*.mlir is a product of a world
# that needs JAX and a 291 MB iree-compile, and the output is one ~790 KB executable
# + `.vmfb` files. The machine that runs it needs neither Python nor Ruby.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../env.sh"

OUT=$HERE/build
MODEL=$HERE/model
rm -rf "$OUT"
mkdir -p "$OUT/spinel"
cp "$SURFACE" "$OUT/spinel/"
cp "$HERE/model.rb" "$HERE/app.rb" "$OUT/"

# --- 1. StableHLO -> .vmfb, per device ----------------------------------------------
# These 2 lines are the whole import: --iree-input-type=stablehlo, and
# the exported module as it is (weights included).
echo "== iree-compile (stablehlo) =="
for m in mnist_mlp mnist_scale; do
  "$IREE_COMPILE" --iree-input-type=stablehlo \
      --iree-hal-target-backends=llvm-cpu \
      "$MODEL/$m.mlir" -o "$OUT/${m}_cpu.vmfb"
  "$IREE_COMPILE" --iree-input-type=stablehlo \
      --iree-hal-target-backends=metal-spirv \
      --iree-metal-compile-to-metallib=false \
      "$MODEL/$m.mlir" -o "$OUT/${m}_metal.vmfb"
  if "$IREE_COMPILE" --iree-hal-list-target-backends 2>/dev/null | grep -qx '  *cuda'; then
    "$IREE_COMPILE" --iree-input-type=stablehlo \
        --iree-hal-target-backends=cuda \
        "$MODEL/$m.mlir" -o "$OUT/${m}_cuda.vmfb"
  fi
done

# --- 2. declarations -> table + dispatch. **Checked against the real modules** ---------
# --extern-check is the point of this layer. A tensor_extern is a **claim** about an
# artifact this tool did not make, and a transcription can lie. Running without it warns.
echo "== spinel-mlirgen --tensor (tensor_extern x2, both checked) =="
(cd "$OUT" && "$MLIRGEN" model.rb --tensor \
    --emit-table sp_tensor_table.h --emit-ruby model.gen.rb \
    --extern-check mnist_mlp="$MODEL/mnist_mlp.mlir" \
    --extern-check mnist_scale="$MODEL/mnist_scale.mlir")

# --- 3. shim + program -------------------------------------------------------------
echo "== shim + spinel =="
"$CC" -O2 -c "$SHIM" -o "$OUT/sp_tensor_shim.o" $IREE_CFLAGS -I"$OUT"
(cd "$OUT" && "$SPINEL" app.rb -o app --link "$OUT/sp_tensor_shim.o" $IREE_LINK)

ls -la "$OUT/app" "$OUT"/*.vmfb
echo "-- dynamic dependencies of what ships (system frameworks only) --"
# Dynamic dependencies are listed with otool -L on macOS and ldd on Linux (portable form).
if command -v otool >/dev/null 2>&1; then otool -L "$OUT/app"; else ldd "$OUT/app"; fi
echo "mnist: built. next: $HERE/run.sh"
