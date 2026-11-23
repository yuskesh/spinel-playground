#!/usr/bin/env bash
# E081 non-regression: everything the changed files carry, re-measured.
#
# E081 touched tools/mlir/spinel-mlirgen (platform externs in the
# --freestanding mode), tools/freestanding/undef-check.py (mapping-form extern
# entries) and added tools/freestanding/extern-check.py.  The standing claim:
#
#   1. every stored freestanding artefact (E040 / E063 / E066 / E067 / E077)
#      reproduces BYTE-IDENTICALLY -- profiles without callable externs take
#      no new code path;
#   2. the host integer and tensor modes emit byte-identical output to the
#      HEAD generator;
#   3. the E077 ABI matrix (68 rows) still says MATCH 68 times;
#   4. (RERUN_GATES=1, the default) the E018 differential (248), the E040
#      QEMU differential (62) and the E063 node differential (31) all rerun
#      green -- the dynamic backing of the byte comparisons (E062).
#      Their scripts write into their own results/ dirs; the regenerated
#      files are diffed against git and restored with `git checkout --`.
#
#   bash run_nonreg.sh   -> nonreg.tsv
set -uo pipefail
# Kept as an oracle; it runs only on the owner's instruction (tools/oracle/gate).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)/tools/oracle/gate" tests/freestanding/e081/oracle/run_nonreg.sh whole || exit 0

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../../workdir.sh"
REPO=$(cd -- "$HERE/../../../.." && pwd)
SCRATCH=${SCRATCH:-/tmp/spinel-llvm-scratch/session-b}
W=$SCRATCH/e081/nonreg
MLIRGEN=$REPO/tools/mlir/spinel-mlirgen
FSDIR=$REPO/tools/freestanding
# `undef-check.py`, `abi-check.py` and `extern-check.py` were retired and
# deleted. **The native tool has the same command lines** (`spinel-fs-check`),
# so only the caller changes. The argv shape is the same, and byte-equal output
# was measured by spot checks when the Python tools were retired.
FSCHECK=${FSCHECK:-$REPO/tools/mlir/native/build/bin/spinel-fs-check}
RESULTS=$REPO/docs/experiments/results
RERUN_GATES=${RERUN_GATES:-1}
# E092/H3: a `git show HEAD:` copy resolves tools/contract/build/spinel-typedump
# relative to ITS OWN path (a scratch dir that has no tools/contract/ beside
# it), so the copy always fails with "typedump not found" unless told where
# the real one is via --typedump (E087's override flag).
TYPEDUMP=$REPO/tools/contract/build/spinel-typedump

fs_fresh_workdir "$W"; mkdir -p "$W/spinel"
cp "$FSDIR/spinel/freestanding.rb" "$W/spinel/"

pass=0; fail=0
emit() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$HERE/nonreg.tsv"
         if [ "$1" = PASS ]; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
printf 'verdict\tid\tnote\n' > "$HERE/nonreg.tsv"

gen() {   # $1 = kernel path, $2 = as-name, $3 = profile tag, $4 = out, $5.. = flags
  local kern=$1 as=$2 prof=$3 out=$4; shift 4
  cp "$kern" "$W/$as"
  (cd "$W" && "$MLIRGEN" "$as" --freestanding \
      --profile "$FSDIR/profiles/$prof.yaml" "$@" -o "$W/$out" ) >/dev/null 2>&1
}

# ---- 1. stored artefacts, byte for byte ----------------------------------
K040=$RESULTS/E040/e040_kern.rb
gen "$K040" e040_kern.rb cortex-m33-zephyr e040.mlir
cmp -s "$W/e040.mlir" "$RESULTS/E040/e040_kern.mlir" \
  && emit PASS e040_mlir "byte-identical" || emit FAIL e040_mlir "moved"
gen "$K040" e040_kern.rb cortex-m33-zephyr kern.cortex-m33-zephyr.o \
    --emit-header "$W/e040.h" --emit-undef-tsv "$W/e040.undef"
cmp -s "$W/e040.undef" "$RESULTS/E040/undef_m33.tsv" \
  && emit PASS e040_undef_m33 "byte-identical" || emit FAIL e040_undef_m33 "moved"
cmp -s "$W/e040.h" "$RESULTS/E040/spinel_freestanding.h" \
  && emit PASS e040_header "byte-identical (no extern section: the profile declares none)" \
  || emit FAIL e040_header "moved"
gen "$K040" e040_kern.rb riscv32-zephyr kern.riscv32-zephyr.o \
    --emit-undef-tsv "$W/e040rv.undef"
cmp -s "$W/e040rv.undef" "$RESULTS/E040/undef_riscv32.tsv" \
  && emit PASS e040_undef_rv32 "byte-identical" || emit FAIL e040_undef_rv32 "moved"

gen "$K040" kern.rb wasm32-worker e063.mlir
cmp -s "$W/e063.mlir" "$RESULTS/E063/e063_kern.mlir" \
  && emit PASS e063_mlir "byte-identical" || emit FAIL e063_mlir "moved"
gen "$K040" kern.rb wasm32-worker kern.o --emit-undef-tsv "$W/e063.undef"
cmp -s "$W/e063.undef" "$RESULTS/E063/undef_wasm32.tsv" \
  && emit PASS e063_undef "byte-identical" || emit FAIL e063_undef "moved"

K067=$REPO/examples/edge-twin/kern.rb
gen "$K067" kern.rb wasm32-worker e067.mlir
cmp -s "$W/e067.mlir" "$RESULTS/E067/e067_kern.mlir" \
  && emit PASS e067_mlir "byte-identical" || emit FAIL e067_mlir "moved"
for p in cortex-m33-zephyr riscv32-zephyr wasm32-worker; do
  gen "$K067" kern.rb "$p" "kern.$p.o" --emit-undef-tsv "$W/e067.$p.undef"
  cmp -s "$W/e067.$p.undef" "$RESULTS/E067/undef.$p.tsv" \
    && emit PASS "e067_undef_$p" "byte-identical" || emit FAIL "e067_undef_$p" "moved"
done

K066=$REPO/examples/gatekeeper/kern.rb
gen "$K066" kern.rb wasm32-worker kern.o --emit-header "$W/e066.h" \
    --emit-undef-tsv "$W/e066.undef"
if [ -s "$W/e066.undef" ] && [ -z "$(awk -F'\t' 'NR>1 && $1=="DENY"' "$W/e066.undef")" ]; then
  emit PASS e066_builds "0 DENY"
else emit FAIL e066_builds "gatekeeper no longer builds clean"; fi
cmp -s "$W/e066.h" "$REPO/examples/gatekeeper/dist/spinel_freestanding.h" \
  && emit PASS e066_header "byte-identical" || emit FAIL e066_header "moved"

K077=$RESULTS/E077/e077_kern.rb
gen "$K077" e077_kern.rb cortex-m33-zephyr e077.mlir
cmp -s "$W/e077.mlir" "$RESULTS/E077/e077_kern.mlir" \
  && emit PASS e077_mlir "byte-identical" || emit FAIL e077_mlir "moved"
gen "$K077" e077_kern.rb cortex-m33-zephyr kern.cortex-m33-zephyr.o \
    --emit-header "$W/e077.h" --emit-undef-tsv "$W/e077.m33.undef"
cmp -s "$W/e077.h" "$RESULTS/E077/spinel_freestanding.h" \
  && emit PASS e077_header "byte-identical" || emit FAIL e077_header "moved"
cmp -s "$W/e077.m33.undef" "$RESULTS/E077/undef.cortex-m33-zephyr.tsv" \
  && emit PASS e077_undef_m33 "byte-identical" || emit FAIL e077_undef_m33 "moved"
for p in riscv32-zephyr wasm32-worker; do
  gen "$K077" e077_kern.rb "$p" "kern.$p.o" --emit-undef-tsv "$W/e077.$p.undef"
  cmp -s "$W/e077.$p.undef" "$RESULTS/E077/undef.$p.tsv" \
    && emit PASS "e077_undef_$p" "byte-identical" || emit FAIL "e077_undef_$p" "moved"
done

# ---- 2. the host modes against the HEAD generator ------------------------
BASE=$W/mlirgen.base
( cd "$REPO" && git show HEAD:tools/mlir/spinel-mlirgen > "$BASE" ) 2>/dev/null
chmod +x "$BASE"
SPBIN=$REPO/vendor/spinel/bin/spinel
mkdir -p "$W/h"
cp "$RESULTS/E018/cases/fib.rb" "$W/h/"
ok=1
for m in raise wrap none; do
  (cd "$W/h" && "$MLIRGEN" fib.rb -m fib --int-overflow "$m" --spinel "$SPBIN" \
      --no-abi-check -o "new.$m.mlir") >/dev/null 2>&1
  (cd "$W/h" && "$BASE" fib.rb -m fib --int-overflow "$m" --spinel "$SPBIN" \
      --no-abi-check -o "base.$m.mlir" --typedump "$TYPEDUMP") >/dev/null 2>&1
  cmp -s "$W/h/new.$m.mlir" "$W/h/base.$m.mlir" || ok=0
done
[ "$ok" = 1 ] && emit PASS host_int_vs_head "3 overflow modes byte-identical to HEAD" \
             || emit FAIL host_int_vs_head "a host mode moved"
if [ -f "$REPO/tools/tensor/spinel/tensor.rb" ]; then
  mkdir -p "$W/t/spinel" "$W/t/km" "$W/t/kmb"
  cp "$REPO/tools/tensor/spinel/tensor.rb" "$W/t/spinel/"
  cp "$RESULTS/E031/sumsq_kernels.rb" "$W/t/"
  ( cd "$W/t" && SPINEL_BIN="$SPBIN" "$MLIRGEN" sumsq_kernels.rb --tensor \
      -o new.mlir --emit-kernel-mlir km --emit-table new.h --emit-ruby new.gen.rb ) >/dev/null 2>&1
  ( cd "$W/t" && SPINEL_BIN="$SPBIN" "$BASE" sumsq_kernels.rb --tensor \
      -o base.mlir --emit-kernel-mlir kmb --emit-table base.h --emit-ruby base.gen.rb \
      --typedump "$TYPEDUMP" ) >/dev/null 2>&1
  if cmp -s "$W/t/new.mlir" "$W/t/base.mlir" && cmp -s "$W/t/new.gen.rb" "$W/t/base.gen.rb" \
     && cmp -s "$W/t/new.h" "$W/t/base.h" && cmp -s "$W/t/km/sumsq.mlir" "$W/t/kmb/sumsq.mlir"; then
    emit PASS tensor_vs_head "module, .gen.rb, table, kernel .mlir byte-identical to HEAD"
  else emit FAIL tensor_vs_head "the tensor mode's output moved"; fi
fi

# ---- 3. the E077 ABI matrix, re-measured ---------------------------------
mkdir -p "$W/abi"
cp "$K077" "$W/abi/e077_kern.rb"; cp -r "$W/spinel" "$W/abi/spinel"
abi_ok=1
{
  printf 'target\tverdict\tsymbol\tfrom_c_header\tfrom_kernel_ir\n'
  for spec in "cortex-m33-zephyr thumbv8m.main-none-eabi -mcpu=cortex-m33+nodsp -mfloat-abi=soft" \
              "riscv32-zephyr riscv32-none-elf -march=rv32imac_zicsr_zifencei -mabi=ilp32" \
              "wasm32-worker wasm32-wasip1"; do
    set -- $spec; tag=$1; triple=$2; shift 2
    (cd "$W/abi" && "$MLIRGEN" e077_kern.rb --freestanding \
        --profile "$FSDIR/profiles/$tag.yaml" -o "k.$tag.ll" \
        --emit-header "h.$tag.h") >/dev/null 2>&1
    "$FSCHECK" --abi "$W/abi/k.$tag.ll" "$W/abi/h.$tag.h" "$triple" "$@" \
      | tail -n +2 | sed "s/^/${tag%%-*}\t/"
  done
  (cd "$W/abi" && "$MLIRGEN" e077_kern.rb --freestanding \
      --profile "$RESULTS/E077/arm64-none.yaml" -o k.arm64.ll \
      --emit-header h.arm64.h) >/dev/null 2>&1
  "$FSCHECK" --abi "$W/abi/k.arm64.ll" "$W/abi/h.arm64.h" arm64-apple-macosx \
    | tail -n +2 | sed 's/^/arm64\t/'
} > "$W/abi/abi.tsv" || abi_ok=0
nrows=$(( $(wc -l < "$W/abi/abi.tsv") - 1 ))
nbad=$(awk -F'\t' 'NR>1 && $2!="MATCH"' "$W/abi/abi.tsv" | wc -l | tr -d ' ')
if [ "$abi_ok" = 1 ] && [ "$nrows" = 68 ] && [ "$nbad" = 0 ]; then
  emit PASS e077_abi_matrix "68/68 MATCH re-measured"
else emit FAIL e077_abi_matrix "rows=$nrows bad=$nbad"; fi

# ---- 4. the heavy gate reruns (dynamic backing, E062) --------------------
if [ "$RERUN_GATES" = 1 ]; then
  # E018: 248 differential.  Writes into results/E018; diff against git, restore.
  ( cd "$RESULTS/E018" && bash run_diff.sh ) > "$W/e018.log" 2>&1
  if tail -3 "$W/e018.log" | grep -q 'OK.*248\|248 OK'; then
    e18=ok
  else
    e18=$(grep -cE '	OK	|	OK$' "$RESULTS/E018/diff.tsv" 2>/dev/null || echo 0)
  fi
  if ( cd "$REPO" && git diff --quiet -- docs/experiments/results/E018/diff.tsv ); then
    emit PASS e018_diff_248 "rerun and diff.tsv is byte-identical to the recorded one"
  else
    ( cd "$REPO" && git diff -- docs/experiments/results/E018 > "$W/e018_rerun.diff" ) || true
    emit FAIL e018_diff_248 "diff.tsv moved (see $W/e018_rerun.diff)"
  fi
  ( cd "$REPO" && git checkout -- docs/experiments/results/E018 ) 2>/dev/null || true

  # E040: the 62-row QEMU differential.
  ( cd "$RESULTS/E040" && SCRATCH="$SCRATCH" bash build_all.sh \
      && SCRATCH="$SCRATCH" bash run_gates.sh ) > "$W/e040.log" 2>&1
  n40=$(awk -F'\t' 'NR>1 && $NF=="PASS"' "$RESULTS/E040/gates.tsv" | wc -l | tr -d ' ')
  if ( cd "$REPO" && git diff --quiet -- docs/experiments/results/E040/gates.tsv ) \
     && [ "$n40" = 62 ]; then
    emit PASS e040_gates_62 "62/62 PASS rerun, gates.tsv byte-identical"
  else
    ( cd "$REPO" && git diff -- docs/experiments/results/E040 > "$W/e040_rerun.diff" ) || true
    emit FAIL e040_gates_62 "pass=$n40 (see $W/e040_rerun.diff and $W/e040.log)"
  fi
  ( cd "$REPO" && git checkout -- docs/experiments/results/E040 ) 2>/dev/null || true

  # E063: the 31-row node differential (+ shape + trap probes).
  ( cd "$RESULTS/E063" && SCRATCH="$SCRATCH" bash build.sh \
      && SCRATCH="$SCRATCH" bash run_gates.sh ) > "$W/e063.log" 2>&1
  n63=$(awk -F'\t' 'NR>1 && $NF=="PASS"' "$RESULTS/E063/gates.tsv" | wc -l | tr -d ' ')
  if ( cd "$REPO" && git diff --quiet -- docs/experiments/results/E063/gates.tsv ) \
     && [ "$n63" = 31 ]; then
    emit PASS e063_gates_31 "31/31 PASS rerun, gates.tsv byte-identical"
  else
    ( cd "$REPO" && git diff -- docs/experiments/results/E063 > "$W/e063_rerun.diff" ) || true
    emit FAIL e063_gates_31 "pass=$n63 (see $W/e063_rerun.diff and $W/e063.log)"
  fi
  ( cd "$REPO" && git checkout -- docs/experiments/results/E063 ) 2>/dev/null || true
fi

cat "$HERE/nonreg.tsv"
echo "nonreg.tsv: pass=$pass fail=$fail"
[ "$fail" = 0 ] || exit 1
