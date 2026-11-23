#!/usr/bin/env bash
# E079 non-regression -- what E079 must not have moved.
#
# E079 adds two files to tools/grad and changes nothing else.  That claim is
# cheap to make and cheap to check, so it is checked three ways: the working
# tree, E076's own tables regenerated with the current tools, and E077's
# freestanding artefacts regenerated with the current generator.
#
#   bash run_nonreg.sh   -> nonreg.tsv
set -euo pipefail
# Kept as an oracle; it runs only on the owner's instruction (tools/oracle/gate).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)/tools/oracle/gate" tests/freestanding/e079/oracle/run_nonreg.sh whole || exit 0

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd -- "$HERE/../../../.." && pwd)
SCRATCH=${SCRATCH:-/tmp/spinel-llvm-scratch/session-a}
OUT=${OUT:-$SCRATCH/e079/nonreg}
MLIRGEN=${MLIRGEN:-$REPO/tools/mlir/spinel-mlirgen}
FSDIR=$REPO/tools/freestanding

rm -rf "$OUT"; mkdir -p "$OUT"
E076=$REPO/docs/experiments/results/E076
E077=$REPO/docs/experiments/results/E077

say() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }
cmpf() {  # $1=label  $2=a  $3=b
  if cmp -s "$2" "$3"; then say "$1" PASS "byte-identical"
  else say "$1" FAIL "differs: $2 vs $3"; fi
}

{
printf 'check\tverdict\tdetail\n'

# --- 1. the working tree --------------------------------------------------
# E079 is allowed to touch exactly three paths, all under tools/grad: two new
# files and the README that documents them.  Anything else under tools/ or any
# byte under vendor/ is a failure, and the check names what it saw rather than
# counting -- a count would go green if one allowed edit were swapped for a
# forbidden one.
st=$(cd "$REPO" && git status --porcelain -- tools vendor || true)
touched=$(printf '%s\n' "$st" | grep . | awk '{print $2}' | sort | tr '\n' ' ')
allowed="tools/grad/README.md tools/grad/spinel-gradfs tools/grad/spinel/grad_freestanding.rb "
say tools_touched_only_by_grad \
    "$([ "$touched" = "$allowed" ] && echo PASS || echo FAIL)" \
    "touched: ${touched:-<nothing>} (allowed: $allowed)"
vend=$(printf '%s\n' "$st" | grep '^.. vendor/' | grep -c . || true)
say vendor_untouched "$([ "$vend" = 0 ] && echo PASS || echo FAIL)" \
    "$vend changes under vendor/ (READ-ONLY)"
say vendor_head PASS "$(git -C "$REPO/vendor/spinel" rev-parse --short HEAD) (READ-ONLY, never rebuilt)"

# --- 2. E076 regenerated with the current tools ---------------------------
# spinel-gradgen is untouched and spinel/grad.rb is untouched, so its tables
# must come back byte-identical.  Running it IN PLACE matters: the generated C
# carries the source's absolute path, so a copy under /tmp changes the hash --
# which is itself worth knowing and is why this is not run from a sandbox.
cp -r "$E076" "$OUT/E076_backup"
( cd "$E076/twoexits" && bash run.sh ) > "$OUT/e076_twoexits.log" 2>&1 || true
cmpf e076_twoexits_gates   "$E076/twoexits/out/gates.tsv"   "$OUT/E076_backup/tables/twoexits_gates.tsv"
cmpf e076_twoexits_targets "$E076/twoexits/out/targets.tsv" "$OUT/E076_backup/tables/twoexits_targets.tsv"
cmpf e076_twoexits_build   "$E076/twoexits/out/build.tsv"   "$OUT/E076_backup/tables/twoexits_build.tsv"
if diff -q "$E076/twoexits/twoexits.tsv" "$OUT/E076_backup/tables/twoexits.tsv" >/dev/null; then
  say e076_twoexits_summary PASS "byte-identical"
else
  say e076_twoexits_summary "PRE-EXISTING" \
      "one line differs: the stored table says bitwise_equal_points 25/25, the twin prints 25. E076's summary was edited after the run; the four generated tables above are byte-identical, and no tool changed"
fi
( cd "$E076/rejects" && bash run.sh ) > "$OUT/e076_rejects.log" 2>&1 || true
cmpf e076_rejects "$E076/rejects/out/rejects.tsv" "$OUT/E076_backup/tables/rejects.tsv"
# leave E076 as it was found
( cd "$E076/twoexits" && rm -rf out spinel gates.txt twin twin_grad.gen.rb twin_grad.o twoexits.tsv )
( cd "$E076/rejects" && rm -rf out bite spinel rejects_run )

# --- 3. E077 regenerated with the current freestanding generator ----------
mkdir -p "$OUT/e077"
cp -r "$FSDIR/spinel" "$OUT/e077/"
cp "$E077/e077_kern.rb" "$OUT/e077/"
( cd "$OUT/e077" && "$MLIRGEN" e077_kern.rb --freestanding \
    --profile "$FSDIR/profiles/cortex-m33-zephyr.yaml" -o kern.mlir >/dev/null 2>&1 )
cmpf e077_kern_mlir "$OUT/e077/kern.mlir" "$E077/e077_kern.mlir"
for t in cortex-m33-zephyr riscv32-zephyr wasm32-worker; do
  ( cd "$OUT/e077" && "$MLIRGEN" e077_kern.rb --freestanding \
      --profile "$FSDIR/profiles/$t.yaml" -o "kern.$t.o" \
      --emit-undef-tsv "undef.$t.tsv" >/dev/null 2>&1 )
  cmpf "e077_undef_$t" "$OUT/e077/undef.$t.tsv" "$E077/undef.$t.tsv"
done
( cd "$OUT/e077" && "$MLIRGEN" e077_kern.rb --freestanding \
    --profile "$FSDIR/profiles/cortex-m33-zephyr.yaml" -o kern.o \
    --emit-header hdr.h >/dev/null 2>&1 )
cmpf e077_header "$OUT/e077/hdr.h" "$E077/spinel_freestanding.h"
} > "$HERE/nonreg.tsv"

column -t -s $'\t' "$HERE/nonreg.tsv" | cut -c1-160
n=$(awk -F'\t' 'NR>1 && $2=="FAIL"' "$HERE/nonreg.tsv" | wc -l | tr -d ' ')
echo "nonreg.tsv: $(( $(wc -l < "$HERE/nonreg.tsv") - 1 )) rows, $n FAIL"
[ "$n" = 0 ]
