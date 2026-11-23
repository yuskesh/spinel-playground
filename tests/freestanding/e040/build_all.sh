#!/usr/bin/env bash
# E040 build -- P003 Phase 1 (M1), ported from spinel-llvm 463d49dd
# docs/experiments/results/E040/build_all.sh.
#
#   Ruby (+ freestanding_def) --> MLIR --> LLVM IR --> .o (thumbv8m / riscv32)
#   --> Zephyr link (west) --> QEMU
#
# Not ported to the runnable path, and why:
#   - the host oracle (the same Ruby through bin/spinel's C back end): a
#     comparison with another implementation; see oracle/.
#   - checkcost.tsv: a size measurement written by inline Python, not a check.
#
#   bash build_all.sh        # generate, cross-compile, west build (3 images)
#   bash run_gates.sh        # QEMU runs + the trap platform
#   bash run_reject.sh       # the static rejection table + undef-gate controls
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
need_zephyr
# Zephyr 4.4 has NO `qemu_cortex_m33` board; the M33 QEMU target is mps2/an521.
M33_BOARD=${M33_BOARD:-mps2/an521/cpu0}
RISCV_BOARD=${RISCV_BOARD:-qemu_riscv32}

fs_fresh_workdir "$OUT"
mkdir -p "$OUT/gen" "$OUT/spinel" "$RES"
cp "$FSDIR/spinel/freestanding.rb" "$OUT/spinel/"
cp "$HERE/e040_kern.rb" "$OUT/"

echo "== toolchain =="
{
  "$CLANG" --version | head -1
  (cd "$REPO/vendor/spinel" && git rev-parse --short HEAD | sed 's/^/vendor\/spinel /')
  (cd "$ZEPHYR_BASE" && git rev-parse --short HEAD | sed 's/^/zephyr /') 2>/dev/null || true
  "$WEST" --version 2>/dev/null || true
} 2>&1 | tee "$RES/toolchain.txt"

# --- 1. the case table ------------------------------------------------------
# mkcases.rb writes cases.inc (compiled into the Zephyr app), expect.tsv and the
# host driver; only cases.inc and the case count are used here.
echo "== mkcases =="
ruby "$HERE/mkcases.rb" "$OUT/gen"

# --- 3. the freestanding objects ------------------------------------------
for tgt in cortex-m33-zephyr riscv32-zephyr; do
  echo "== spinel-fs-emit --freestanding --profile $tgt =="
  (cd "$OUT" && "$MLIRGEN" e040_kern.rb --freestanding \
      --profile "$FSDIR/profiles/$tgt.yaml" \
      -o "gen/kern.$tgt.o" \
      --emit-header "gen/spinel_freestanding.$tgt.h" \
      --emit-undef-tsv "gen/undef.$tgt.tsv" 2>&1 | tail -2)
  [ -f "$OUT/gen/kern.$tgt.o" ] || { echo "no object for $tgt" >&2; exit 1; }
  (cd "$OUT" && "$MLIRGEN" e040_kern.rb --freestanding \
      --profile "$FSDIR/profiles/$tgt.yaml" -o "gen/kern.$tgt.mlir" >/dev/null 2>&1)
  (cd "$OUT" && "$MLIRGEN" e040_kern.rb --freestanding \
      --profile "$FSDIR/profiles/$tgt.yaml" -o "gen/kern.$tgt.ll" >/dev/null 2>&1)
  cp "$OUT/gen/undef.$tgt.tsv" "$RES/undef.$tgt.tsv"
done
cp "$OUT/gen/spinel_freestanding.cortex-m33-zephyr.h" "$RES/spinel_freestanding.h"

# --- 3b. the static ABI check ---------------------------------------------
# The generated header, compiled by the target's C compiler, against the
# signature the kernel object defines. spinel-llvm ran abi_check.py here and
# later spinel-fs-check --abi, which has the same CLI; this uses the latter.
{
  printf 'target\tverdict\tsymbol\tfrom_c_header\tfrom_kernel_ir\n'
  "$FSCHECK" --abi "$OUT/gen/kern.cortex-m33-zephyr.ll" \
      "$OUT/gen/spinel_freestanding.cortex-m33-zephyr.h" thumbv8m.main-none-eabi \
      -mcpu=cortex-m33+nodsp -mfloat-abi=soft | tail -n +2 | sed 's/^/cortex-m33\t/'
  "$FSCHECK" --abi "$OUT/gen/kern.riscv32-zephyr.ll" \
      "$OUT/gen/spinel_freestanding.riscv32-zephyr.h" riscv32-none-elf \
      -march=rv32imac_zicsr_zifencei -mabi=ilp32 | tail -n +2 | sed 's/^/riscv32\t/'
} > "$RES/abi.tsv"
nbad=$(awk -F'\t' 'NR>1 && $2!="MATCH"' "$RES/abi.tsv" | wc -l | tr -d ' ')
echo "abi.tsv: $(( $(wc -l < "$RES/abi.tsv") - 1 )) rows, $nbad disagreement(s)"
# A mismatch here is a silent-miscompile bug, so it stops the build.
[ "$nbad" = 0 ] || { echo "abi.tsv has $nbad disagreement(s)" >&2; exit 1; }

# determinism: the same inputs must give the same bytes
echo "== determinism =="
(cd "$OUT" && "$MLIRGEN" e040_kern.rb --freestanding \
    --profile "$FSDIR/profiles/cortex-m33-zephyr.yaml" -o gen/rerun.mlir >/dev/null 2>&1)
cmp "$OUT/gen/kern.cortex-m33-zephyr.mlir" "$OUT/gen/rerun.mlir"
echo "determinism: the .mlir is byte-identical across runs"

# --- 4. Zephyr images ------------------------------------------------------
build_zephyr() {   # $1=tag  $2=board  $3=profile-tag  $4+=extra cmake args
  local tag=$1 board=$2 prof=$3; shift 3
  local b="$OUT/build_$tag"
  cp "$OUT/gen/spinel_freestanding.$prof.h" "$OUT/gen/spinel_freestanding.h"
  echo "== west build $tag ($board) =="
  "$WEST" build -p always -b "$board" -d "$b" "$HERE/zephyr" -- \
      -DSPINEL_OBJ="$OUT/gen/kern.$prof.o" \
      -DSPINEL_GEN_DIR="$OUT/gen" "$@" > "$OUT/west_$tag.log" 2>&1 || {
    tail -20 "$OUT/west_$tag.log" >&2; echo "west build $tag failed" >&2; exit 1; }
  grep -m1 -- '-- Found toolchain' "$OUT/west_$tag.log" || true
  tail -2 "$OUT/west_$tag.log"
}
build_zephyr m33      "$M33_BOARD"     cortex-m33-zephyr
build_zephyr m33panic "$M33_BOARD"     cortex-m33-zephyr -DE040_PANIC_TRAP=1
build_zephyr riscv32  "$RISCV_BOARD"   riscv32-zephyr
echo "build_all: done"
