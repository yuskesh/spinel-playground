#!/usr/bin/env bash
# examples/edge-twin -- build the two halves of the twin from the ONE kern.rb.
#
#   ./build.sh                 wasm (always) + Zephyr images (if Zephyr is set up)
#   ./build.sh --no-device     skip the QEMU/Zephyr half
#
# Output:
#   dist/                      a workerd project: kern.wasm + index.mjs + twin.mjs
#   $EDGE_TWIN_BUILD/gen/      kern.o for each target, and the generated header
#   $EDGE_TWIN_BUILD/dev-m33/, dev-rv32/, dev-trap/   Zephyr images
#
# The Zephyr/QEMU build trees are ~40 MB of CMake and object files, so they live
# OUTSIDE the repository by default (~/.cache/spinel-llvm/edge-twin).  Set
# EDGE_TWIN_BUILD to put them somewhere else; dist/ always stays here, because it
# is the thing you deploy.
#
# Prerequisites: vendor/spinel built, llvm@22 + lld + wasi-runtimes, node.  The
# device half additionally needs Zephyr + the Zephyr SDK + QEMU
# (docs/tools/zephyr.md, zephyr-sdk.md, qemu.md).  See README.md.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/../.." && pwd)

# spinel-llvm called its tools/mlir/spinel-mlirgen front; this repository has
# the native emitter it routed to, which takes the same argv.
MLIRGEN=${MLIRGEN:-${SPINEL_CORE_BUILD:-$ROOT/tools/mlir/native/build}/bin/spinel-fs-emit}
FSDIR=$ROOT/tools/freestanding
: "${LLVM_PREFIX:?set LLVM_PREFIX to the official LLVM 23.1.1}"
NM="$LLVM_PREFIX/bin/llvm-nm"
WASM_LD=${WASM_LD:-$LLVM_PREFIX/bin/wasm-ld}
: "${WASI_BUILTINS:?set WASI_BUILTINS to libclang_rt.builtins.a for wasm32-unknown-wasip1}"

WITH_DEVICE=1
[ "${1:-}" = "--no-device" ] && WITH_DEVICE=0

OUT=${EDGE_TWIN_BUILD:-${TMPDIR:-/tmp}/spinel-edge-twin}
GEN=$OUT/gen
rm -rf "$OUT" "$HERE/dist"
mkdir -p "$GEN" "$HERE/dist" "$OUT/src/spinel"

# `require_relative "spinel/freestanding"` resolves next to the kernel file, so
# the surface is copied in rather than referenced.  The example does not keep
# its own copy of it (the same rule examples/tensor/* follow).
cp "$FSDIR/spinel/freestanding.rb" "$OUT/src/spinel/"
cp "$HERE/kern.rb" "$OUT/src/"

# --- 1. the same kernel, three targets ------------------------------------
# The command line is IDENTICAL apart from --profile.  That is the claim: an
# edge worker and a Cortex-M33 are two values of one flag.
gen_for() {   # $1 = profile tag
  echo "== spinel-mlirgen --freestanding --profile $1 =="
  (cd "$OUT/src" && "$MLIRGEN" kern.rb --freestanding \
      --profile "$FSDIR/profiles/$1.yaml" \
      -o "$GEN/kern.$1.o" \
      --emit-header "$GEN/spinel_freestanding.$1.h" \
      --emit-undef-tsv "$GEN/undef.$1.tsv" 2>&1 | tail -1)
}
gen_for wasm32-worker
if [ "$WITH_DEVICE" = 1 ]; then
  gen_for cortex-m33-zephyr
  gen_for riscv32-zephyr
fi

# --- 2. the worker ---------------------------------------------------------
# The export list is read out of the object: the freestanding_def declarations
# are the boundary, and a list written here could disagree with them.
EXPORTS=()
while read -r sym; do EXPORTS+=("--export=$sym"); done < <(
  "$NM" --defined-only --extern-only "$GEN/kern.wasm32-worker.o" | awk '{print $3}' | sort)
# No crt, no libc, no _initialize: a freestanding module has nothing to
# initialise, so the reactor contract would be 327 bytes of decoration (E063 §3).
"$WASM_LD" --no-entry --allow-undefined --strip-all "${EXPORTS[@]}" \
    "$GEN/kern.wasm32-worker.o" "$WASI_BUILTINS" -o "$HERE/dist/kern.wasm"

cp "$HERE/worker/index.mjs" "$HERE/worker/twin.mjs" "$HERE/worker/wrangler.toml" "$HERE/dist/"

# The worker's view of the boundary, derived from the GENERATED header so that
# no signature is ever transcribed by hand (E040 §6 found a real bug in exactly
# the gap between a header and the code behind it).
ruby "$ROOT/examples/tools/kern_sig.rb" "$GEN/spinel_freestanding.wasm32-worker.h" "$HERE/dist/sig.json" "dist/sig.json"

printf 'dist/kern.wasm: %s bytes (gzip %s)\n' \
    "$(wc -c < "$HERE/dist/kern.wasm" | tr -d " ")" \
    "$(gzip -9 -c "$HERE/dist/kern.wasm" | wc -c | tr -d ' ')"

# --- 3. the device ---------------------------------------------------------
if [ "$WITH_DEVICE" = 1 ]; then
  export ZEPHYR_BASE="${ZEPHYR_BASE:-}"
  export ZEPHYR_SDK_INSTALL_DIR="${ZEPHYR_SDK_INSTALL_DIR:-}"
  export ZEPHYR_TOOLCHAIN_VARIANT="${ZEPHYR_TOOLCHAIN_VARIANT:-zephyr}"
  WEST=${WEST:-west}
  # Zephyr 4.4 has no `qemu_cortex_m33` board; the M33 QEMU target is mps2/an521.
  M33_BOARD=${M33_BOARD:-mps2/an521/cpu0}
  RISCV_BOARD=${RISCV_BOARD:-qemu_riscv32}

  if [ -z "$ZEPHYR_BASE" ] || [ ! -d "$ZEPHYR_BASE" ] || ! command -v "$WEST" >/dev/null 2>&1; then
    echo "edge-twin: no Zephyr at '$ZEPHYR_BASE' (or no west) for the device half; pass --no-device to build the worker half alone." >&2
    exit 1
  fi

  build_dev() {   # $1=tag  $2=board  $3=profile  $4.. extra cmake args
    local tag=$1 board=$2 prof=$3; shift 3
    cp "$GEN/spinel_freestanding.$prof.h" "$GEN/spinel_freestanding.h"
    echo "== west build $tag ($board) =="
    "$WEST" build -p always -b "$board" -d "$OUT/$tag" "$HERE/device" -- \
        -DSPINEL_OBJ="$GEN/kern.$prof.o" -DSPINEL_GEN_DIR="$GEN" "$@" 2>&1 | tail -4
  }
  build_dev dev-m33   "$M33_BOARD"   cortex-m33-zephyr
  build_dev dev-rv32  "$RISCV_BOARD" riscv32-zephyr
  build_dev dev-trap  "$M33_BOARD"   cortex-m33-zephyr -DEDGE_TWIN_TRAP_PROBE=1
fi

echo
echo "edge-twin: built.  dist/ is here; the build tree is $OUT"
echo "           next: ./run_demo.sh"
