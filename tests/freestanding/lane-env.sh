# tests/freestanding/lane-env.sh -- sourced by every lane script, after it sets
# HERE to its own directory. It replaces the per-script defaults the lanes had
# in spinel-llvm, which named a developer's home directory and Homebrew paths.
# Nothing here has a home-directory default: a tool this repository does not
# build is named by the caller or the lane stops.
#
#   LLVM_PREFIX            the official LLVM 23.1.1 (docs/building.md); required
#   ZEPHYR_BASE            a Zephyr v4.4.2 tree; required by the device lanes
#   ZEPHYR_SDK_INSTALL_DIR the Zephyr SDK 1.0.1; required by the device lanes.
#                          Only a HINT to Zephyr's CMake: the lanes print the
#                          toolchain Zephyr actually found, and that is the one used.
#   WASI_BUILTINS          compiler-rt builtins for wasm32-unknown-wasip1; required
#                          by the wasm32 lanes (the LLVM release ships none)
#   WASI_SYSROOT           a wasi-libc sysroot; required by e063 (the wasip1
#                          reactor link)
#   NODE                   node, for the wasm32 lanes (default: node on PATH)
#   WRANGLER               wrangler, for e063/run_worker.sh (default: on PATH)
#   ENZYME                 the Enzyme plugin built against LLVM 23.1.1; required by
#                          the gradient lanes (e079, e083, e084)
#   BAREMETAL_BUILTINS     compiler-rt builtins for Cortex-M33 (thumbv8m.main, soft
#                          float), built from LLVM 23.1.1; required by bm040
#                          (docs/toolchains/compiler-rt-23.1.1)
#   QEMU_ARM               qemu-system-arm with mps2-an521, for bm040 (default:
#                          on PATH; not the Zephyr SDK's)
#   FS_WORK                where lanes write (default: $TMPDIR/spinel-freestanding)
#
# Each lane writes under OUT, which is $FS_WORK/<lane> and is never taken from
# the environment: the lanes remove it, and OUT is a name callers export.

REPO=$(cd -- "$HERE/../../.." && pwd)
: "${LLVM_PREFIX:?set LLVM_PREFIX to the official LLVM 23.1.1 (docs/building.md)}"
CLANG=${CLANG:-$LLVM_PREFIX/bin/clang}
NM=${NM:-$LLVM_PREFIX/bin/llvm-nm}
WASM_LD=${WASM_LD:-$LLVM_PREFIX/bin/wasm-ld}
NODE=${NODE:-node}
# spinel-llvm's tools/mlir/spinel-mlirgen routed `--freestanding --profile` to
# the native emitter; this repository has only the emitter, which accepts the
# same argv (its "product spelling"). The lanes keep the name MLIRGEN.
. "$REPO/tests/freestanding/stamps.sh"
UNDEF=${UNDEF:-$FSCHECK}
FSDIR=$REPO/tools/freestanding
LANE=$(basename -- "$HERE")
# Built from this tree's source, or the lane stops here, before it writes
# anything (stamps.sh).
fs_stamps || { echo "$LANE: the native tools are not this tree's build (above); rebuild them" >&2; exit 2; }
OUT=${FS_WORK:-${TMPDIR:-/tmp}/spinel-freestanding}/$LANE
. "$HERE/../workdir.sh"
# Created marked, so a later build_all.sh may empty it.
[ -e "$OUT" ] || fs_fresh_workdir "$OUT"
# RES holds what the predecessor wrote beside its scripts (tables, consoles,
# generated headers). Writing it here keeps the source tree clean.
RES=${RES:-$OUT/results}
for t in "$MLIRGEN" "$FSCHECK" "$CLANG" "$NM"; do
  [ -x "$t" ] || { echo "$LANE: no executable at $t" >&2; exit 2; }
done

need_zephyr() {
  : "${ZEPHYR_BASE:?set ZEPHYR_BASE to a Zephyr v4.4.2 tree}"
  : "${ZEPHYR_SDK_INSTALL_DIR:?set ZEPHYR_SDK_INSTALL_DIR to the Zephyr SDK 1.0.1}"
  export ZEPHYR_BASE ZEPHYR_SDK_INSTALL_DIR
  export ZEPHYR_TOOLCHAIN_VARIANT=${ZEPHYR_TOOLCHAIN_VARIANT:-zephyr}
  WEST=${WEST:-west}
  command -v "$WEST" >/dev/null 2>&1 || { echo "$LANE: no west on PATH" >&2; exit 2; }
}
need_enzyme() {
  : "${ENZYME:?set ENZYME to the Enzyme plugin built against LLVM 23.1.1 (tools/grad/README.md)}"
  [ -f "$ENZYME" ] || { echo "$LANE: no file at ENZYME=$ENZYME" >&2; exit 2; }
  [ -x "$FSGRAD" ] || { echo "$LANE: no executable at $FSGRAD" >&2; exit 2; }
}
# What tools/grad/spinel-gradgen reads besides the native build (tools/grad/README.md,
# Dependencies; the same list as tests/grad/env.sh). Without the runtime bitcode,
# rtcheck writes no verdict and gradgen refuses every declaration at O5.
need_gradgen() {
  _bc=${BC_DIR:-$REPO/tools/llvm/build}/libspinel_rt_lto.a
  [ -f "$_bc" ] || { echo "$LANE: no runtime bitcode at $_bc (build it with tools/llvm/build_rt_bc.sh)" >&2; exit 2; }
  _p=$REPO/tools/llvm/passes/build/libSpinelGCRoots.so
  [ -f "$_p" ] || { echo "$LANE: no pass plugin at $_p (build it with cmake and ninja, tools/llvm/passes/README.md)" >&2; exit 2; }
  _t=$REPO/tools/contract/build/spinel-typedump
  [ -x "$_t" ] || { echo "$LANE: no executable at $_t (build it with tools/contract/build.sh)" >&2; exit 2; }
}
need_baremetal() {
  if [ -z "${BAREMETAL_BUILTINS:-}" ]; then
    echo "$LANE: set BAREMETAL_BUILTINS to compiler-rt's libclang_rt.builtins-armv8m.main.a (docs/toolchains/compiler-rt-23.1.1)" >&2
    exit 2
  fi
  [ -f "$BAREMETAL_BUILTINS" ] || { echo "$LANE: no file at BAREMETAL_BUILTINS=$BAREMETAL_BUILTINS" >&2; exit 2; }
  QEMU_ARM=${QEMU_ARM:-qemu-system-arm}
  command -v "$QEMU_ARM" >/dev/null 2>&1 || { echo "$LANE: no QEMU at QEMU_ARM=$QEMU_ARM" >&2; exit 2; }
}
need_wasm() {
  : "${WASI_BUILTINS:?set WASI_BUILTINS to libclang_rt.builtins.a for wasm32-unknown-wasip1}"
  [ -f "$WASI_BUILTINS" ] || { echo "$LANE: no file at WASI_BUILTINS=$WASI_BUILTINS" >&2; exit 2; }
  [ -x "$WASM_LD" ] || { echo "$LANE: no wasm-ld at $WASM_LD" >&2; exit 2; }
  command -v "$NODE" >/dev/null 2>&1 || { echo "$LANE: no node ('$NODE')" >&2; exit 2; }
}
