#!/usr/bin/env bash
# E084 build -- Newton-CG with the Hessian-vector product inside the kernel.
# Ported from spinel-llvm 463d49dd docs/experiments/results/E084/build_all.sh.
#
#   e084_kern.rb --[spinel-fs-emit --freestanding]--> kern.<t>.o
#                     (the kernel: entries + `newton_calibrate`, which imports
#                      spinel_grad_sq_hinge_loss and spinel_hvp_sq_hinge_loss
#                      as platform externs declared with buffer parameters)
#                --[spinel-fs-grad --grads-only]-----> grad.<t>.o
#                     (the Enzyme adjoint and the forward-over-reverse hvp)
#
# then: the wasm link, the native executable (+ two trap-probe builds), and
# three Zephyr images (m33, rv32, m33 trap probe).
#
# Local changes: as in ../e083/build_all.sh (spinel-fs-grad for spinel-gradfs,
# the host leg `host`, tables in $RES, extern_check NOT-PORTED). Not built:
# analytic_check, the closed-form Hessian written by hand (an oracle, in oracle/).
#
#   bash build_all.sh     # generate + cross-compile + link + west build
#   bash run_gates.sh     # the four legs, symmetry, the loop, traps, surface
#   bash run_host.sh      # the host pipeline on the same problem
#   bash run_reject.sh    # the compile-time rejection table
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
need_enzyme
need_wasm
M33_BOARD=${M33_BOARD:-mps2/an521/cpu0}
RISCV_BOARD=${RISCV_BOARD:-qemu_riscv32}
NO_DEVICE=${NO_DEVICE:-0}
[ "$NO_DEVICE" = 1 ] || need_zephyr
case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) HOSTPROF=arm64-host-e084.yaml ;;
  Linux/x86_64) HOSTPROF=x86_64-host-e084.yaml ;;
  *) echo "e084: no host profile for $(uname -s)/$(uname -m)" >&2; exit 2 ;;
esac

fs_fresh_workdir "$OUT"
mkdir -p "$OUT/gen" "$OUT/logs" "$OUT/spinel" "$RES"
cp "$FSDIR/spinel/freestanding.rb" "$REPO/tools/grad/spinel/grad_freestanding.rb" "$OUT/spinel/"
cp "$HERE/e084_kern.rb" "$HERE/"*-e084.yaml "$OUT/"

echo "== toolchain =="
{
  "$CLANG" --version | head -1
  "$WASM_LD" --version
  git -C "$REPO/vendor/spinel" rev-parse --short HEAD | sed 's/^/vendor\/spinel /'
  echo "enzyme $ENZYME"
  "$NODE" --version | sed 's/^/node /'
} 2>&1 | tee "$RES/toolchain.txt"

prof_of() {
  case "$1" in
    host) echo "$OUT/$HOSTPROF" ;;
    *)    echo "$OUT/$1-e084.yaml" ;;
  esac
}
triple_of() { awk '/^  triple:/{print $2; exit}' "$(prof_of "$1")"; }
cflags_of() {  # every "- <flag>" under target.cflags
  awk '/^  cflags:/{on=1;next} on&&/^    - /{print $2} on&&!/^    - /{exit}' "$(prof_of "$1")"
}
TARGETS="host cortex-m33-zephyr riscv32-zephyr wasm32-worker"

# --- 1. four targets, two generators, two objects each ---------------------
for t in $TARGETS; do
  p=$(prof_of "$t")
  echo "== $t: kernel (imports the adjoint) =="
  (cd "$OUT" && "$MLIRGEN" e084_kern.rb --freestanding --profile "$p" \
      -o "gen/kern.$t.o" --emit-header "gen/spinel_freestanding.$t.h" \
      --emit-undef-tsv "gen/undef.kern.$t.tsv" 2>&1 | tail -1)
  (cd "$OUT" && "$MLIRGEN" e084_kern.rb --freestanding --profile "$p" \
      -o "gen/kern.$t.ll" >/dev/null 2>&1)
  echo "== $t: adjoint (--grads-only) =="
  (cd "$OUT" && "$FSGRAD" e084_kern.rb --profile "$p" --grads-only \
      -o gen --tag "$t" --emit-header "gen/spinel_grad.$t.h" --enzyme "$ENZYME" 2>&1 | tail -1)
  for f in "kern.$t.o" "grad.$t.o"; do
    [ -f "$OUT/gen/$f" ] || { echo "e084: no $f" >&2; exit 1; }
  done
  cp "$OUT/gen/undef.kern.$t.tsv" "$RES/undef.kern.$t.tsv"
  cp "$OUT/gen/undef.$t.tsv" "$RES/undef.grad.$t.tsv"
done

# --- 2. determinism + G5 over the loop, not just the adjoint ---------------
{
  printf 'check\tverdict\tdetail\n'
  (cd "$OUT" && "$MLIRGEN" e084_kern.rb --freestanding \
      --profile "$(prof_of cortex-m33-zephyr)" -o gen/rerun.ll >/dev/null 2>&1)
  if cmp -s "$OUT/gen/kern.cortex-m33-zephyr.ll" "$OUT/gen/rerun.ll"; then
    printf 'generator_determinism\tPASS\tthe .ll is byte-identical across runs\n'
  else
    printf 'generator_determinism\tFAIL\t.ll differs between two runs\n'
  fi
  (cd "$OUT" && "$FSGRAD" e084_kern.rb --profile "$(prof_of cortex-m33-zephyr)" \
      --grads-only -o gen2 --tag rerun --enzyme "$ENZYME" >/dev/null 2>&1)
  if cmp -s "$OUT/gen/grad.cortex-m33-zephyr.o" "$OUT/gen2/grad.rerun.o"; then
    printf 'fsgrad_determinism\tPASS\tgrad.o (adjoint+hvp) byte-identical across runs\n'
  else
    printf 'fsgrad_determinism\tFAIL\tgrad.o differs between two runs\n'
  fi
  for t in $TARGETS; do
    n=$(grep -cE '= *(fneg|fadd|fsub|fmul|fdiv|frem|fcmp|select|call) +((fast|nnan|ninf|nsz|arcp|contract|afn|reassoc) +)+' \
        "$OUT/gen/kern.$t.ll" || true)
    if [ "$n" = 0 ]; then
      printf 'g5_kernel_loop.%s\tPASS\t0 fast-math sites in the kernel .ll (loop included)\n' "$t"
    else
      printf 'g5_kernel_loop.%s\tFAIL\t%s fast-math site(s) in the kernel .ll\n' "$t" "$n"
    fi
    fm=$(awk -F'\t' '$1=="fastmath_sites"{print $2}' "$OUT/gen/build.$t.tsv")
    if [ "$fm" = 0 ]; then
      printf 'g5_adjoint_and_hvp.%s\tPASS\tspinel-fs-grad reports 0 fast-math sites (reverse and forward-over-reverse)\n' "$t"
    else
      printf 'g5_adjoint_and_hvp.%s\tFAIL\tfastmath_sites=%s\n' "$t" "$fm"
    fi
    fa=$(awk -F'\t' '$1=="fwd_adjoints"{print $2}' "$OUT/gen/build.$t.tsv")
    if printf '%s' "$fa" | grep -q 'fwddiffe'; then
      printf 'fwd_adjoint_present.%s\tPASS\t%s\n' "$t" "$(printf '%s' "$fa" | cut -c1-60)..."
    else
      printf 'fwd_adjoint_present.%s\tFAIL\tno fwddiffe* in build.tsv\n' "$t"
    fi
  done
} > "$RES/determinism.tsv"
cat "$RES/determinism.tsv"

# --- 3. the ABI matrix, extern declaration included ------------------------
{
  printf 'target\tmatch\ttotal\tverdict\n'
  for t in $TARGETS; do
    triple=$(triple_of "$t")
    CF=()
    while read -r f; do [ -n "$f" ] && CF+=("$f"); done < <(cflags_of "$t")
    out=$("$FSCHECK" --abi "$OUT/gen/kern.$t.ll" \
          "$OUT/gen/spinel_freestanding.$t.h" "$triple" ${CF[@]+"${CF[@]}"} 2>/dev/null) || true
    total=$(printf '%s\n' "$out" | tail -n +2 | wc -l | tr -d ' ')
    match=$(printf '%s\n' "$out" | awk -F'\t' '$1=="MATCH"' | wc -l | tr -d ' ')
    printf '%s\t%s\t%s\t%s\n' "$t" "$match" "$total" \
      "$([ "$match" = "$total" ] && [ "$total" != 0 ] && echo MATCH || echo MISMATCH)"
    printf '%s\n' "$out" > "$OUT/gen/abi.$t.tsv"
  done
} > "$RES/abi.tsv"
cat "$RES/abi.tsv"

# --- 4. extern-check: not ported --------------------------------------------
# spinel-llvm checked the profile's declaration against the C shim the retired
# spinel-gradfs wrote (shim.<t>.c), which defined the adjoint symbol. The native
# spinel-fs-grad builds that shim in IR (shim.<t>.ll) and writes no C, and
# `spinel-fs-check --extern` needs a C definition: the generated header's
# prototype is refused as MISSING ("the wrapper TU must DEFINE it"). The row is
# written as NOT-PORTED rather than passed or failed.
{
  printf 'verdict\tsymbol\treason\n'
  printf 'NOT-PORTED\tspinel_grad_sq_hinge_loss\tthe adjoint is defined by an IR shim; extern-check reads a C definition\n'
  printf 'NOT-PORTED\tspinel_hvp_sq_hinge_loss\tthe hvp product is defined by an IR shim; extern-check reads a C definition\n'
} > "$RES/extern_check.tsv"
cat "$RES/extern_check.tsv"

# --- 5. the wasm module: two objects, one import ---------------------------
echo "== wasm-ld =="
EXPORTS=()
while read -r sym; do EXPORTS+=("--export=$sym"); done < <(
  "$NM" --defined-only --extern-only "$OUT/gen/kern.wasm32-worker.o" \
        "$OUT/gen/grad.wasm32-worker.o" | awk 'NF==3{print $3}' | sort -u)
"$WASM_LD" --no-entry --allow-undefined --strip-all "${EXPORTS[@]}" \
    --export=__heap_base "$OUT/gen/kern.wasm32-worker.o" \
    "$OUT/gen/grad.wasm32-worker.o" "$WASI_BUILTINS" -o "$OUT/gen/kern.wasm"

# --- 6. the native executable + the trap probes ----------------------------
echo "== native =="
cp "$OUT/gen/spinel_freestanding.host.h" "$OUT/gen/spinel_freestanding.h"
cp "$OUT/gen/spinel_grad.host.h" "$OUT/gen/spinel_grad.h"
for v in ":native" "-DE084_TRAP=1:native_trap1" "-DE084_TRAP=-6:native_trapneg"; do
  def=${v%%:*}; exe=${v#*:}
  "$CLANG" -O2 $def -I "$OUT/gen" -I "$HERE/drv" -o "$OUT/$exe" \
      "$HERE/drv/native_main.c" "$OUT/gen/kern.host.o" "$OUT/gen/grad.host.o"
done

# --- 7. sizes --------------------------------------------------------------
{
  printf 'what\tbytes\n'
  for t in $TARGETS; do
    printf 'kernel.%s\t%s\n' "$t" \
      "$("$LLVM_PREFIX/bin/llvm-size" "$OUT/gen/kern.$t.o" | awk 'NR==2{print $1}')"
    printf 'adjoint_plus_hvp.%s\t%s\n' "$t" \
      "$("$LLVM_PREFIX/bin/llvm-size" "$OUT/gen/grad.$t.o" | awk 'NR==2{print $1}')"
  done
  printf 'wasm.raw\t%s\n' "$(wc -c < "$OUT/gen/kern.wasm" | tr -d ' ')"
  printf 'alloca_in_grad_module\t%s\n' \
    "$(awk -F'\t' '$1=="alloca_in_module"{print $2}' "$OUT/gen/build.host.tsv")"
} > "$RES/size.tsv"
cat "$RES/size.tsv"

# --- 8. the device images --------------------------------------------------
if [ "$NO_DEVICE" = 1 ]; then
  echo "== skipping the device images (NO_DEVICE=1) =="
  exit 0
fi
build_zephyr() {   # $1=tag  $2=board  $3=profile-tag  $4+=extra cmake args
  local tag=$1 board=$2 prof=$3; shift 3
  cp "$OUT/gen/spinel_freestanding.$prof.h" "$OUT/gen/spinel_freestanding.h"
  cp "$OUT/gen/spinel_grad.$prof.h" "$OUT/gen/spinel_grad.h"
  echo "== west build $tag ($board) =="
  "$WEST" build -p always -b "$board" -d "$OUT/build_$tag" "$HERE/zephyr" -- \
      -DSPINEL_OBJ="$OUT/gen/kern.$prof.o" \
      -DSPINEL_GRAD_OBJ="$OUT/gen/grad.$prof.o" \
      -DSPINEL_GEN_DIR="$OUT/gen" -DE084_DRV_DIR="$HERE/drv" "$@" 2>&1 | tail -3
  [ -f "$OUT/build_$tag/zephyr/zephyr.elf" ] || { echo "e084: west build $tag failed" >&2; exit 1; }
}
build_zephyr m33     "$M33_BOARD"   cortex-m33-zephyr
build_zephyr riscv32 "$RISCV_BOARD" riscv32-zephyr
build_zephyr m33trap "$M33_BOARD"   cortex-m33-zephyr -DE084_TRAP=1
echo "build_all: done"
