#!/usr/bin/env bash
# E077 build -- P003 Phase 2 (Float and pointer+length buffers across the
# boundary), ported from spinel-llvm 463d49dd
# docs/experiments/results/E077/build_all.sh.
#
#   Ruby kernel --> .o for thumbv8m / riscv32 / wasm32 (+ an arm64 host object
#   for the ABI table) --> Zephyr link (west) and wasm-ld
#
# Not ported to the runnable path, and why:
#   - the host oracle (bin/spinel's C back end): an oracle; see oracle/.
#   - position_ambiguity.txt (show_ambiguity.py) and the per-function sizes
#     (inline Python): records written by Python, not checks.
#
#   bash build_all.sh && bash run_gates.sh && bash run_reject.sh
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
need_zephyr
need_wasm
M33_BOARD=${M33_BOARD:-mps2/an521/cpu0}
RISCV_BOARD=${RISCV_BOARD:-qemu_riscv32}
NO_DEVICE=${NO_DEVICE:-0}

fs_fresh_workdir "$OUT"
mkdir -p "$OUT/gen" "$OUT/spinel" "$RES"
cp "$FSDIR/spinel/freestanding.rb" "$OUT/spinel/"
cp "$HERE/e077_kern.rb" "$OUT/"

echo "== toolchain =="
{
  "$CLANG" --version | head -1
  "$WASM_LD" --version
  (cd "$REPO/vendor/spinel" && git rev-parse --short HEAD | sed 's/^/vendor\/spinel /')
  (cd "$ZEPHYR_BASE" && git rev-parse --short HEAD | sed 's/^/zephyr /') 2>/dev/null || true
  "$WEST" --version 2>/dev/null || true
  "$NODE" --version | sed 's/^/node /'
} 2>&1 | tee "$RES/toolchain.txt"

# --- 1. the case table ------------------------------------------------------
# cases.inc from the tracked cases.json with E166's Ruby mkcases_inc.rb, which
# spinel-llvm wrote to replace mkcases.py's make_cases_inc().
echo "== cases.inc from cases.json =="
cp "$HERE/cases.json" "$OUT/gen/cases.json"
ruby "$HERE/mkcases_inc.rb" "$HERE/cases.json" > "$OUT/gen/cases.inc"

# --- 3. the freestanding objects, three targets ---------------------------
for tgt in cortex-m33-zephyr riscv32-zephyr wasm32-worker; do
  echo "== spinel-fs-emit --freestanding --profile $tgt =="
  (cd "$OUT" && "$MLIRGEN" e077_kern.rb --freestanding \
      --profile "$FSDIR/profiles/$tgt.yaml" \
      -o "gen/kern.$tgt.o" \
      --emit-header "gen/spinel_freestanding.$tgt.h" \
      --emit-undef-tsv "gen/undef.$tgt.tsv" 2>&1 | tail -1)
  [ -f "$OUT/gen/kern.$tgt.o" ] || { echo "no object for $tgt" >&2; exit 1; }
  for f in mlir ll; do
    (cd "$OUT" && "$MLIRGEN" e077_kern.rb --freestanding \
        --profile "$FSDIR/profiles/$tgt.yaml" -o "gen/kern.$tgt.$f" >/dev/null 2>&1)
  done
  cp "$OUT/gen/undef.$tgt.tsv" "$RES/undef.$tgt.tsv"
done
# check_exports.py, in Ruby: every symbol the drivers name is in the header.
ruby -rjson -e '
  have = File.read(ARGV[0]).scan(/\b(spinel_[A-Za-z0-9_]+)\s*\(/).flatten.uniq
  want = JSON.parse(File.read(ARGV[1]))["cases"].map { |c| c["sym"] }.uniq
  missing = want - have
  abort "check_exports: the drivers name symbols the generated header does not have: #{missing.sort.join(", ")}" unless missing.empty?
  puts "export map: #{want.size} symbol(s), all present in the generated header"
' "$OUT/gen/spinel_freestanding.cortex-m33-zephyr.h" "$OUT/gen/cases.json"
cp "$OUT/gen/spinel_freestanding.cortex-m33-zephyr.h" "$RES/spinel_freestanding.h"

# determinism
(cd "$OUT" && "$MLIRGEN" e077_kern.rb --freestanding \
    --profile "$FSDIR/profiles/cortex-m33-zephyr.yaml" -o gen/rerun.mlir >/dev/null 2>&1)
cmp "$OUT/gen/kern.cortex-m33-zephyr.mlir" "$OUT/gen/rerun.mlir"
echo "determinism: the .mlir is byte-identical across runs"

# --- ABI: the generated header against the kernel IR, per target -----------
# spinel-fs-check --abi compiles the header with the target's C compiler and
# compares each prototype's lowering with the signature the object defines.
echo "== ABI: sizes, alignment and calling convention, both directions =="
{
  printf 'target\tverdict\tsymbol\tfrom_c_header\tfrom_kernel_ir\n'
  "$FSCHECK" --abi "$OUT/gen/kern.cortex-m33-zephyr.ll" \
      "$OUT/gen/spinel_freestanding.cortex-m33-zephyr.h" thumbv8m.main-none-eabi \
      -mcpu=cortex-m33+nodsp -mfloat-abi=soft | tail -n +2 | sed 's/^/cortex-m33\t/'
  "$FSCHECK" --abi "$OUT/gen/kern.riscv32-zephyr.ll" \
      "$OUT/gen/spinel_freestanding.riscv32-zephyr.h" riscv32-none-elf \
      -march=rv32imac_zicsr_zifencei -mabi=ilp32 | tail -n +2 | sed 's/^/riscv32\t/'
  "$FSCHECK" --abi "$OUT/gen/kern.wasm32-worker.ll" \
      "$OUT/gen/spinel_freestanding.wasm32-worker.h" wasm32-wasip1 \
      | tail -n +2 | sed 's/^/wasm32\t/'
  (cd "$OUT" && "$MLIRGEN" e077_kern.rb --freestanding \
      --profile "$HERE/arm64-none.yaml" -o gen/kern.arm64.ll >/dev/null 2>&1 \
   && "$MLIRGEN" e077_kern.rb --freestanding --profile "$HERE/arm64-none.yaml" \
      -o gen/kern.arm64.o --emit-header gen/spinel_freestanding.arm64.h \
      >/dev/null 2>&1) || true
  if [ -f "$OUT/gen/kern.arm64.ll" ]; then
    "$FSCHECK" --abi "$OUT/gen/kern.arm64.ll" \
        "$OUT/gen/spinel_freestanding.arm64.h" arm64-apple-macosx \
        | tail -n +2 | sed 's/^/arm64\t/'
  fi
} > "$RES/abi.tsv"
nbad=$(awk -F'\t' 'NR>1 && $2!="MATCH"' "$RES/abi.tsv" | wc -l | tr -d ' ')
echo "abi.tsv: $(( $(wc -l < "$RES/abi.tsv") - 1 )) rows, $nbad disagreement(s)"
[ "$nbad" = 0 ] || { echo "abi.tsv has $nbad disagreement(s)" >&2; exit 1; }

# --- wasm link -------------------------------------------------------------
echo "== wasm-ld =="
EXPORTS=()
while read -r sym; do EXPORTS+=("--export=$sym"); done < <(
  "$NM" --defined-only --extern-only "$OUT/gen/kern.wasm32-worker.o" | awk '{print $3}' | sort)
"$WASM_LD" --no-entry --allow-undefined --strip-all "${EXPORTS[@]}" \
    --export=__heap_base \
    "$OUT/gen/kern.wasm32-worker.o" "$WASI_BUILTINS" -o "$OUT/gen/kern.wasm"

# --- sizes and the surviving bounds checks (a record) ----------------------
{
  printf 'what\tbytes\n'
  for t in cortex-m33-zephyr riscv32-zephyr wasm32-worker; do
    printf 'object.%s\t%s\n' "$t" \
      "$("$LLVM_PREFIX/bin/llvm-size" "$OUT/gen/kern.$t.o" | awk 'NR==2{print $1}')"
  done
  printf 'wasm.raw\t%s\n' "$(wc -c < "$OUT/gen/kern.wasm" | tr -d ' ')"
  printf 'bounds.sites.mlir\t%s\n' \
    "$(grep -c 'index out of bounds' "$OUT/gen/kern.cortex-m33-zephyr.mlir")"
  for t in cortex-m33-zephyr riscv32-zephyr wasm32-worker; do
    printf 'bounds.survived.%s\t%s\n' "$t" \
      "$(strings "$OUT/gen/kern.$t.o" | grep -c 'index out of bounds' || true)"
  done
} > "$RES/size.tsv"
cat "$RES/size.tsv"

if [ "$NO_DEVICE" = 1 ]; then
  echo "== skipping the device images (NO_DEVICE=1) =="
  exit 0
fi
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
build_zephyr m33      "$M33_BOARD"    cortex-m33-zephyr
build_zephyr m33panic "$M33_BOARD"    cortex-m33-zephyr -DE077_PANIC_TRAP=1
build_zephyr riscv32  "$RISCV_BOARD"  riscv32-zephyr
echo "build_all: done"
