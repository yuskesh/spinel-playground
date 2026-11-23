#!/usr/bin/env bash
# E079 build -- P007 Phase 3 (the gradient on every exit). Ported from
# spinel-llvm 463d49dd docs/experiments/results/E079/build_all.sh.
#
#   e079_kern.rb --[spinel-fs-emit --freestanding]--> kern.<t>.o  (the kernel)
#                --[spinel-fs-grad]---------------> grad.<t>.o  (kernel + adjoint)
#                for t in host / cortex-m33-zephyr / riscv32-zephyr / wasm32-worker
#
# then: the wasm link, the native executable, and two Zephyr images.
#
# Local changes: spinel-fs-grad (native, Enzyme in-process) where spinel-llvm
# called its retired spinel-gradfs, with the same arguments plus --enzyme; the
# host leg is this machine's (arm64-host.yaml on macOS arm64, x86_64-host.yaml
# on x86-64 Linux) and its tag is `host`; the tables are written to $RES.
#
#   bash build_all.sh     # generate + cross-compile + link + west build
#   bash run_gates.sh     # the four legs, the traps and the closed loop
#   bash run_reject.sh    # the rejection table
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
  Darwin/arm64) HOSTPROF=$HERE/arm64-host.yaml ;;
  Linux/x86_64) HOSTPROF=$HERE/x86_64-host.yaml ;;
  *) echo "e079: no host profile for $(uname -s)/$(uname -m)" >&2; exit 2 ;;
esac

fs_fresh_workdir "$OUT"
mkdir -p "$OUT/gen" "$OUT/logs" "$OUT/spinel" "$RES"
cp "$FSDIR/spinel/freestanding.rb" "$REPO/tools/grad/spinel/grad_freestanding.rb" "$OUT/spinel/"
cp "$HERE/e079_kern.rb" "$OUT/"

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
    host) echo "$HOSTPROF" ;;
    *)    echo "$FSDIR/profiles/$1.yaml" ;;
  esac
}
TARGETS="host cortex-m33-zephyr riscv32-zephyr wasm32-worker"

# --- 1. four targets, two generators each ---------------------------------
for t in $TARGETS; do
  p=$(prof_of "$t")
  echo "== $t: kernel =="
  (cd "$OUT" && "$MLIRGEN" e079_kern.rb --freestanding --profile "$p" \
      -o "gen/kern.$t.o" --emit-header "gen/spinel_freestanding.$t.h" \
      --emit-undef-tsv "gen/undef.kern.$t.tsv" 2>&1 | tail -1)
  (cd "$OUT" && "$MLIRGEN" e079_kern.rb --freestanding --profile "$p" \
      -o "gen/kern.$t.ll" >/dev/null 2>&1)
  echo "== $t: gradient =="
  (cd "$OUT" && "$FSGRAD" e079_kern.rb --profile "$p" -o gen --tag "$t" \
      --emit-header "gen/spinel_grad.$t.h" --enzyme "$ENZYME" 2>&1 | tail -1)
  [ -f "$OUT/gen/grad.$t.o" ] || { echo "e079: no gradient object for $t" >&2; exit 1; }
  cp "$OUT/gen/undef.$t.tsv" "$RES/undef.$t.tsv"
done

# --- 2. determinism, and the declaration's inertness -----------------------
#   (a) the generator is deterministic: two runs, the same .ll
#   (b) adding `freestanding_grad_def` changes the kernel's IR not at all
{
  printf 'check\tverdict\tdetail\n'
  (cd "$OUT" && "$MLIRGEN" e079_kern.rb --freestanding \
      --profile "$(prof_of cortex-m33-zephyr)" -o gen/rerun.ll >/dev/null 2>&1)
  if cmp -s "$OUT/gen/kern.cortex-m33-zephyr.ll" "$OUT/gen/rerun.ll"; then
    printf 'generator_determinism\tPASS\tthe .ll is byte-identical across runs\n'
  else
    printf 'generator_determinism\tFAIL\t.ll differs between two runs\n'
  fi
  grep -v '^freestanding_grad_def' "$OUT/e079_kern.rb" > "$OUT/nograd_kern.rb"
  for t in $TARGETS; do
    (cd "$OUT" && "$MLIRGEN" nograd_kern.rb --freestanding --profile "$(prof_of "$t")" \
        -o "gen/nograd.$t.ll" >/dev/null 2>&1)
    if cmp -s "$OUT/gen/kern.$t.ll" "$OUT/gen/nograd.$t.ll"; then
      printf 'grad_decl_inert.%s\tPASS\tsame .ll with and without freestanding_grad_def\n' "$t"
    else
      printf 'grad_decl_inert.%s\tFAIL\tthe declaration changed the kernel IR\n' "$t"
    fi
  done
} > "$RES/determinism.tsv"
cat "$RES/determinism.tsv"

# --- 3. the wasm module ----------------------------------------------------
wasm_link() {  # $1 = object, $2 = output
  local exports=()
  while read -r sym; do exports+=("--export=$sym"); done < <(
    "$NM" --defined-only --extern-only "$1" | awk '{print $3}' | sort)
  "$WASM_LD" --no-entry --allow-undefined --strip-all "${exports[@]}" \
      --export=__heap_base "$1" "$WASI_BUILTINS" -o "$2"
}
echo "== wasm-ld =="
wasm_link "$OUT/gen/grad.wasm32-worker.o" "$OUT/gen/kern.wasm"

# --- 4. the native executable ---------------------------------------------
echo "== native =="
cp "$OUT/gen/spinel_freestanding.host.h" "$OUT/gen/spinel_freestanding.h"
cp "$OUT/gen/spinel_grad.host.h" "$OUT/gen/spinel_grad.h"
"$CLANG" -O2 -I "$OUT/gen" -I "$HERE/drv" -o "$OUT/native" \
    "$HERE/drv/native_main.c" "$OUT/gen/grad.host.o"

# --- 5. the fast-math control (E079 s4) -----------------------------------
# The same kernel with Enzyme's default fast-math, for the native and wasm32
# legs. A record beside the shipped build, not a check (run_gates.sh).
echo "== fast-math control =="
mkdir -p "$OUT/fm"
(cd "$OUT" && "$FSGRAD" e079_kern.rb --profile "$(prof_of host)" -o fm --tag host \
    --fast-math --enzyme "$ENZYME" >/dev/null 2>&1)
(cd "$OUT" && "$FSGRAD" e079_kern.rb --profile "$(prof_of wasm32-worker)" -o fm \
    --tag wasm32-worker --fast-math --enzyme "$ENZYME" >/dev/null 2>&1)
"$CLANG" -O2 -I "$OUT/gen" -I "$HERE/drv" -o "$OUT/native_fm" \
    "$HERE/drv/native_main.c" "$OUT/fm/grad.host.o"
wasm_link "$OUT/fm/grad.wasm32-worker.o" "$OUT/fm/kern.wasm"

# --- 6. sizes --------------------------------------------------------------
{
  printf 'what\tbytes\n'
  for t in $TARGETS; do
    printf 'kernel_only.%s\t%s\n' "$t" \
      "$("$LLVM_PREFIX/bin/llvm-size" "$OUT/gen/kern.$t.o" | awk 'NR==2{print $1}')"
    printf 'kernel_plus_adjoint.%s\t%s\n' "$t" \
      "$("$LLVM_PREFIX/bin/llvm-size" "$OUT/gen/grad.$t.o" | awk 'NR==2{print $1}')"
  done
  printf 'wasm.raw\t%s\n' "$(wc -c < "$OUT/gen/kern.wasm" | tr -d ' ')"
  printf 'alloca_in_adjoint\t%s\n' \
    "$(awk -F'\t' '$1=="alloca_in_module"{print $2}' "$OUT/gen/build.host.tsv")"
} > "$RES/size.tsv"
cat "$RES/size.tsv"

# --- 7. the device images --------------------------------------------------
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
      -DSPINEL_OBJ="$OUT/gen/grad.$prof.o" \
      -DSPINEL_GEN_DIR="$OUT/gen" -DE079_DRV_DIR="$HERE/drv" "$@" 2>&1 | tail -4
  [ -f "$OUT/build_$tag/zephyr/zephyr.elf" ] || { echo "e079: west build $tag failed" >&2; exit 1; }
}
build_zephyr m33     "$M33_BOARD"   cortex-m33-zephyr
build_zephyr riscv32 "$RISCV_BOARD" riscv32-zephyr
echo "build_all: done"
