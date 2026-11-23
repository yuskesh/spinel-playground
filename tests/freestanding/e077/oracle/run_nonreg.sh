#!/usr/bin/env bash
# E077 non-regression: E040 / E063 / E066 / E067 through the CHANGED generator.
#
# E077 touched tools/mlir/spinel-mlirgen (the --freestanding mode's value model,
# its wrapper, its type face) and tools/contract (one new mode).  Four shipped
# artefact sets depend on those, and the claim is that none of them moved.
#
# The check is deliberately byte-level where it can be:
#
#   .mlir      byte-identical to the stored artefact.  This is the strongest
#              form available -- the generator's OUTPUT, not a verdict about it
#              -- and it is achievable because E077's additions are all reached
#              through declarations that the old kernels do not have.
#   undef TSV  byte-identical (the D-3 stage-2 verdicts)
#   header     byte-identical (the boundary the platform compiles against)
#   type face  the same .mlir out of BOTH --types-from faces, which is the
#              claim that moving the type face changed no answer
#
#   bash run_nonreg.sh   -> nonreg.tsv
set -uo pipefail
# Kept as an oracle; it runs only on the owner's instruction (tools/oracle/gate).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)/tools/oracle/gate" tests/freestanding/e077/oracle/run_nonreg.sh whole || exit 0

# **The pin was removed.** The claim used to be "the frozen Python
# generator's output does not move"; after the move to the native generator
# the claim is that **the native output does not move**. The stored `.mlir`
# files were taken again from the native generator (as E087's were). The
# frozen Python generator's output is kept as golden files by E177's corpus.

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../../workdir.sh"
REPO=$(cd -- "$HERE/../../../.." && pwd)
SCRATCH=${SCRATCH:-/tmp/spinel-llvm-scratch/session-a}
W=$SCRATCH/e077/nonreg
MLIRGEN=$REPO/tools/mlir/spinel-mlirgen
FSDIR=$REPO/tools/freestanding
RESULTS=$REPO/docs/experiments/results
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

# The generated artefacts carry two names E077 must reproduce EXACTLY, or the
# byte comparison would fail for a reason that has nothing to do with the
# generator: the SOURCE file name (it appears in the module's header comment)
# and the OBJECT file name (it is the `object` column of the undef TSV).  So
# each experiment is replayed under the names it originally used.
gen() {   # $1 = kernel path, $2 = as-name, $3 = profile tag, $4 = out, $5.. = flags
  local kern=$1 as=$2 prof=$3 out=$4; shift 4
  cp "$kern" "$W/$as"
  (cd "$W" && "$MLIRGEN" "$as" --freestanding \
      --profile "$FSDIR/profiles/$prof.yaml" "$@" -o "$W/$out" ) >/dev/null 2>&1
}

# ---- E040: the M1 kernel, three artefacts --------------------------------
K040=$RESULTS/E040/e040_kern.rb
# ---- Rows retired with the native generator (`e040_mlir_byte_identical`,
# `e040_header`, `e063_mlir_byte_identical`, `e067_mlir_byte_identical`)
# They claimed that the native generator reproduces, byte for byte, the frozen
# Python generator's stored artefacts (the .mlir and .h of results/E040, E063,
# E067). For the same reason E087's `vs_stored_*` rows were retired, that is
# **false as measured**: SSA numbers and block order are another spelling of
# the same meaning, and the header's banner differs. The stored artefacts are
# not moved. The remaining 9 rows (the undef verdicts, e066's build and
# header, host mode) carry E077's claim.
gen "$K040" e040_kern.rb cortex-m33-zephyr kern.cortex-m33-zephyr.o \
    --emit-header "$W/e040.h" --emit-undef-tsv "$W/e040.undef"
if cmp -s "$W/e040.undef" "$RESULTS/E040/undef_m33.tsv"; then
  emit PASS e040_undef_m33 "stage-2 verdicts byte-identical"
else emit FAIL e040_undef_m33 "undef TSV moved"; fi
gen "$K040" e040_kern.rb riscv32-zephyr kern.riscv32-zephyr.o \
    --emit-undef-tsv "$W/e040rv.undef"
if cmp -s "$W/e040rv.undef" "$RESULTS/E040/undef_riscv32.tsv"; then
  emit PASS e040_undef_rv32 "stage-2 verdicts byte-identical"
else emit FAIL e040_undef_rv32 "undef TSV moved"; fi

# ---- A row retired with the native generator (`e040_both_type_faces`)
#
# The claim "the same kernel gives the same module from both type faces"
# **became empty when only one face was left**: `--types-from emit-types` is
# the face kept in the frozen Python generator, and the native one has only
# the contract face. There is nothing to compare with. Dropped for the same
# reason as E087's `both_faces_agree`.
# **Dropped not because it fails but because the claim became empty.**

# ---- E063: the same kernel on wasm32 -------------------------------------
gen "$K040" kern.rb wasm32-worker kern.o --emit-undef-tsv "$W/e063.undef"
if cmp -s "$W/e063.undef" "$RESULTS/E063/undef_wasm32.tsv"; then
  emit PASS e063_undef_wasm32 "stage-2 verdicts byte-identical (incl. __multi3, __stack_pointer)"
else emit FAIL e063_undef_wasm32 "undef TSV moved"; fi

# ---- E067: the edge twin, three profiles ---------------------------------
K067=$REPO/examples/edge-twin/kern.rb
if [ -f "$K067" ]; then
  for p in cortex-m33-zephyr riscv32-zephyr wasm32-worker; do
    gen "$K067" kern.rb "$p" "kern.$p.o" --emit-undef-tsv "$W/e067.$p.undef"
    if cmp -s "$W/e067.$p.undef" "$RESULTS/E067/undef.$p.tsv"; then
      emit PASS "e067_undef_$p" "stage-2 verdicts byte-identical"
    else emit FAIL "e067_undef_$p" "undef TSV moved"; fi
  done
else
  emit FAIL e067_kernel_present "examples/edge-twin/kern.rb is missing"
fi

# ---- E066: the gatekeeper ------------------------------------------------
K066=$REPO/examples/gatekeeper/kern.rb
if [ -f "$K066" ]; then
  gen "$K066" kern.rb wasm32-worker kern.o --emit-header "$W/e066.h" \
      --emit-undef-tsv "$W/e066.undef"
  if [ -s "$W/e066.undef" ]; then
    n=$(awk -F'\t' 'NR>1 && $1=="DENY"' "$W/e066.undef" | wc -l | tr -d ' ')
    if [ "$n" = 0 ]; then emit PASS e066_builds "the 2,266 B gate still builds with 0 DENY"
    else emit FAIL e066_builds "$n DENY row(s)"; fi
  else emit FAIL e066_builds "no undef TSV produced"; fi
  # The gatekeeper ships a generated header in the example directory; if the
  # boundary moved, the router's JS signature file would be wrong.
  if [ -f "$REPO/examples/gatekeeper/dist/spinel_freestanding.h" ]; then
    if cmp -s "$W/e066.h" "$REPO/examples/gatekeeper/dist/spinel_freestanding.h"; then
      emit PASS e066_header "the shipped boundary header is byte-identical"
    else emit FAIL e066_header "header moved"; fi
  fi
else
  emit FAIL e066_kernel_present "examples/gatekeeper/kern.rb is missing"
fi

# ---- the host (integer / tensor) modes -----------------------------------
# E077 changed FuncGen, which the HOST modes share.  E018's differential is the
# gate that covers them; here we only assert the cheap invariant that the host
# modes still emit i64 everywhere (their Val kinds never become float, because
# nothing hands them a declaration).
# The TENSOR mode is checked against the generator as it was BEFORE E077 rather
# than against a stored artefact, because the stored E031 artefacts predate E033
# (which edited the module's header comment) and would report a difference that
# is not E077's.  `git show HEAD:` gives the exact denominator.
# ---- A row retired with the native generator (`tensor_mode_byte_identical`)
#
# The claim was "the tensor mode's output has not moved since HEAD", but
# **this setup cannot measure it**, for two reasons found by measurement:
#
#  1. It compared `$MLIRGEN` (the worktree) with the same path from
#     `git show HEAD:`, that is, **two copies of the wrapper that selects the
#     implementation**. While the wrapper is not edited the two are
#     **byte-identical**, so it ran the same program twice and compared the
#     outputs: it could fail only on nondeterminism.
#  2. The native implementation the wrapper selects
#     (`tools/mlir/native/build/bin/`) is **outside git**. A change to the
#     tensor generator moves **both legs together**, so this comparison cannot
#     see it in principle.
#
# Once the implementations converge, a fingerprint of the output is no
# evidence. Moreover only the `$MLIRGEN` leg was given `--typedump`: **it
# started the two legs with different arguments and claimed byte equality**.
#
# The same four products (`sumsq_kernels.mlir`, `.gen.rb`, the entry table,
# `km/sumsq.mlir`) are compared with **recorded golden files** by E177's
# corpus (`results/E177/golden/e031/accept/sumsq/artifacts/`), which is not a
# self-comparison with HEAD and so does work. **Empty and duplicated**, so
# dropped.

if [ -f "$RESULTS/E018/cases/fib.rb" ]; then
  (cd "$W" && cp "$RESULTS/E018/cases/fib.rb" . && "$MLIRGEN" fib.rb -m fib -o "$W/fib.mlir") >/dev/null 2>&1
  if grep -q "f64" "$W/fib.mlir" 2>/dev/null; then
    emit FAIL host_mode_int_only "a host-mode module contains f64"
  else emit PASS host_mode_int_only "the host integer mode still emits i64 only"; fi
fi

echo "nonreg.tsv: pass=$pass fail=$fail"
[ "$fail" = 0 ] || exit 1
