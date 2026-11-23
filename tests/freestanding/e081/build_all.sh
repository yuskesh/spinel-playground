#!/usr/bin/env bash
# E081 build -- P003 Phase 4 (platform extern), ported from spinel-llvm 463d49dd
# docs/experiments/results/E081/build_all.sh.
#
#   Ruby kernel (calls profile-declared externs)
#     --> MLIR (llvm.call @spinel_zephyr_*) --> .o for thumbv8m / riscv32 / wasm32
#     --> Zephyr link (west; the wrapper TU spinel_zephyr.c supplies the
#         symbols) and wasm-ld (the JS host supplies them as env.* imports)
#
# Not ported to the runnable path: the host oracle (the same Ruby through
# bin/spinel's C back end with Ruby stubs). It is a comparison with another
# implementation and runs only on the user's instruction; see oracle/README.md.
#
#   bash build_all.sh        # generate, cross-compile, west build (3 images), link wasm
#   bash run_extern_check.sh # declaration vs wrapper                -> extern_check.tsv
#   bash run_gates.sh        # device runs: traps + platform properties
#   bash run_reject.sh       # the static rejection table            -> reject.tsv
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
cp "$HERE/e081_kern.rb" "$OUT/"

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
# spinel-llvm generated cases.inc with mkcases.py and later with E166's Ruby
# mkcases_inc.rb, from the tracked cases.json; this uses the Ruby one.
echo "== cases.inc from cases.json =="
cp "$HERE/cases.json" "$OUT/gen/cases.json"
ruby "$HERE/mkcases_inc.rb" "$HERE/cases.json" > "$OUT/gen/cases.inc"

# --- 3. the freestanding objects, three targets ---------------------------
for tgt in cortex-m33-zephyr riscv32-zephyr wasm32-worker; do
  echo "== spinel-fs-emit --freestanding --profile ${tgt}-e081 =="
  (cd "$OUT" && "$MLIRGEN" e081_kern.rb --freestanding \
      --profile "$HERE/$tgt-e081.yaml" \
      -o "gen/kern.$tgt.o" \
      --emit-header "gen/spinel_freestanding.$tgt.h" \
      --emit-undef-tsv "gen/undef.$tgt.tsv" 2>&1 | tail -1)
  [ -f "$OUT/gen/kern.$tgt.o" ] || { echo "no object for $tgt" >&2; exit 1; }
  for f in mlir ll; do
    (cd "$OUT" && "$MLIRGEN" e081_kern.rb --freestanding \
        --profile "$HERE/$tgt-e081.yaml" -o "gen/kern.$tgt.$f" >/dev/null 2>&1)
  done
  cp "$OUT/gen/undef.$tgt.tsv" "$RES/undef.$tgt.tsv"
done
# check_exports.py, in Ruby: every symbol the drivers name is in the generated
# header, and the header carries the 7 declared extern prototypes.
ruby -rjson -e '
  have = File.read(ARGV[0]).scan(/\b(spinel_[A-Za-z0-9_]+)\s*\(/).flatten.uniq
  want = JSON.parse(File.read(ARGV[1]))["cases"].map { |c| c["sym"] }.uniq
  missing = want - have
  abort "check_exports: the drivers name symbols the generated header does not have: #{missing.sort.join(", ")}" unless missing.empty?
  ext = have.select { |s| s.start_with?("spinel_zephyr_") }
  abort "check_exports: expected the 7 declared extern prototypes in the header, found #{ext.size} (#{ext.sort.join(", ")})" unless ext.size == 7
  puts "export map: #{want.size} kernel symbol(s) + #{ext.size} extern prototype(s), all in the generated header"
' "$OUT/gen/spinel_freestanding.cortex-m33-zephyr.h" "$OUT/gen/cases.json"

cp "$OUT/gen/spinel_freestanding.cortex-m33-zephyr.h" "$RES/spinel_freestanding.h"

# determinism (the E040/E063/E077 check)
(cd "$OUT" && "$MLIRGEN" e081_kern.rb --freestanding \
    --profile "$HERE/cortex-m33-zephyr-e081.yaml" -o gen/rerun.mlir >/dev/null 2>&1)
cmp "$OUT/gen/kern.cortex-m33-zephyr.mlir" "$OUT/gen/rerun.mlir"
echo "determinism: the .mlir is byte-identical across runs"

# --- 4. the undef gate as a CONTROL TABLE ---------------------------------
# The allowance for the extern symbols must come from the DECLARATION and from
# nowhere else: the same object under the SHIPPED profile (which has no
# callable externs) must be refused, symbol by symbol.
echo "== undef gate controls =="
{
  printf 'id\texpect\tgot\tverdict\tnote\n'
  chk() {  # id, expect(ALLOW-ALL|DENY:n), profile, obj
    local id=$1 expect=$2 prof=$3 obj=$4 got verdict
    if out=$("$UNDEF" --undef --profile "$prof" "$obj" 2>/dev/null); then
      got="ALLOW-ALL"
    else
      got="DENY:$(printf '%s\n' "$out" | awk -F'\t' '$1=="DENY"' | wc -l | tr -d ' ')"
    fi
    [ "$got" = "$expect" ] && verdict=PASS || verdict=FAIL
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$expect" "$got" "$verdict" "$5"
  }
  chk e1_declared ALLOW-ALL "$HERE/cortex-m33-zephyr-e081.yaml" \
      "$OUT/gen/kern.cortex-m33-zephyr.o" \
      "the e081 profile allows exactly what it declares"
  chk e2_shipped_profile DENY:7 "$FSDIR/profiles/cortex-m33-zephyr.yaml" \
      "$OUT/gen/kern.cortex-m33-zephyr.o" \
      "the SAME object under the shipped (extern-free) profile: 7 unknown symbols"
  chk e3_wasm_declared ALLOW-ALL "$HERE/wasm32-worker-e081.yaml" \
      "$OUT/gen/kern.wasm32-worker.o" \
      "wasm32: the platform:none profile with explicit symbols"
  chk e4_wasm_shipped DENY:7 "$FSDIR/profiles/wasm32-worker.yaml" \
      "$OUT/gen/kern.wasm32-worker.o" \
      "wasm32 under the shipped profile: the 7 extern imports are refused"
} > "$RES/undef_gate.tsv"
cat "$RES/undef_gate.tsv"
[ -z "$(awk -F'\t' 'NR>1 && $4!="PASS"' "$RES/undef_gate.tsv")" ] || {
  echo "undef_gate.tsv has failures" >&2; exit 1; }

# --- 6. wasm link ---------------------------------------------------------
echo "== wasm-ld =="
EXPORTS=()
while read -r sym; do EXPORTS+=("--export=$sym"); done < <(
  "$NM" --defined-only --extern-only "$OUT/gen/kern.wasm32-worker.o" | awk '{print $3}' | sort)
"$WASM_LD" --no-entry --allow-undefined --strip-all "${EXPORTS[@]}" \
    "$OUT/gen/kern.wasm32-worker.o" "$WASI_BUILTINS" -o "$OUT/gen/kern.wasm"

# The module's import section IS the platform surface, named by the module
# itself (E063 s4, now with the extern surface in it).
"$NODE" "$HERE/run_node.mjs" "$OUT/gen/kern.wasm" "$OUT/gen/cases.json" --shape \
  > "$RES/shape.tsv"
n_imp=$(awk -F'\t' '$1=="import"' "$RES/shape.tsv" | wc -l | tr -d ' ')
echo "shape.tsv: $n_imp imports"
[ "$n_imp" = 8 ] || { echo "expected 8 imports (trap + 7 externs), got $n_imp" >&2; exit 1; }

# --- 7. sizes -------------------------------------------------------------
{
  printf 'what\tbytes\n'
  for t in cortex-m33-zephyr riscv32-zephyr wasm32-worker; do
    printf 'object.%s\t%s\n' "$t" \
      "$("$LLVM_PREFIX/bin/llvm-size" "$OUT/gen/kern.$t.o" | awk 'NR==2{print $1}')"
  done
  printf 'wasm.raw\t%s\n' "$(wc -c < "$OUT/gen/kern.wasm" | tr -d ' ')"
} > "$RES/size.tsv"
cat "$RES/size.tsv"

# --- 8. Zephyr images -----------------------------------------------------
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
build_zephyr m33panic "$M33_BOARD"    cortex-m33-zephyr -DE081_PANIC_TRAP=1
build_zephyr riscv32  "$RISCV_BOARD"  riscv32-zephyr
echo "build_all: done"
