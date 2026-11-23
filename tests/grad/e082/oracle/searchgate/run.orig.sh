#!/bin/sh
# E082 -- S1's generalisation into a permanent gate (spinel-searchgate),
# with its own bite-proof and the E080 retrofit.
#
# Requires ../rules/run.sh to have run (the demo minimises the REAL
# spg_*_lut_loss surface from that build).
#
#   1. three searchers, same objective, same starts: correct / anchor
#      (E078 s6's defect) / bestsofar (min-so-far reporting -- the shape S1
#      alone blesses and S2/S3 catch).
#   2. spinel-searchgate over each trace; the EXPECTED verdicts are part of
#      the gate (a checker that can only say OK is not a checker).
#   3. the E080 retrofit: its committed margin curves are population
#      aggregates, and the checker REFUSES them (AGGREGATE-UNAUDITABLE)
#      instead of blessing a curve that cannot carry per-run S1.
set -e
# Kept as an oracle; it runs only on the owner's instruction (tools/oracle/gate).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tests/grad/e082/oracle/searchgate/run.orig.sh whole || exit 0
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../../../.." && pwd)
LLVM=/opt/homebrew/opt/llvm/bin
SG="$ROOT/tools/grad/spinel-searchgate"
E080="$ROOT/docs/experiments/results/E080/tables"
cd "$HERE"
rm -rf out
mkdir -p out
test -f ../rules/out/rules_kernels_diff.ll || { echo "run ../rules/run.sh first" >&2; exit 1; }

echo "== 1: build + run the three searchers =="
$LLVM/clang -O2 -Wno-everything descent_demo.c ../rules/out/rules_kernels_diff.ll \
  ../rules/out/rules_impl.o -o out/descent_demo -lm \
  -L "$ROOT/vendor/spinel/lib" -lspinel_rt
for m in correct anchor bestsofar control; do
  ./out/descent_demo "$m" > "out/trace_$m.tsv" 2> "out/log_$m.txt"
done
echo "-- every searcher prints 'converged' (the report does not audit the search):"
grep -h converged out/log_correct.txt out/log_anchor.txt out/log_bestsofar.txt | head -9

echo "== 2: the gates =="
expect() { # $1 mode, $2 expected exit
  if "$SG" "out/trace_$1.tsv" --control out/trace_control.tsv \
       --out "out/gates_$1.tsv" > /dev/null 2>&1
  then got=0; else got=1; fi
  if [ "$got" = "$2" ]; then v=PASS; else v=FAIL; fi
  printf '%s\texpected_exit=%s\tgot=%s\t%s\n' "$1" "$2" "$got" "$v"
}
{
  printf 'searcher\texpected\tgot\tverdict\n'
  expect correct 0
  expect anchor 1
  expect bestsofar 1
} | tee e082_searchgate_biteproof.tsv

echo "== 3: the E080 retrofit (aggregate curves are refused, not blessed) =="
{
  printf 'trace\tverdict\tdetail\n'
  for c in margin_curve_eps255 margin_curve_eps8; do
    line=$("$SG" "$E080/$c.tsv" 2>/dev/null | sed -n 2p || true)
    printf '%s\t%s\n' "$c" "$(printf '%s' "$line" | cut -f3,4)"
  done
} | tee e082_searchgate_e080.tsv

cat out/gates_correct.tsv > e082_searchgate_gates.tsv
echo "done: e082_searchgate_{biteproof,e080,gates}.tsv"
