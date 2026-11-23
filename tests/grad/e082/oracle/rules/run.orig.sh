#!/bin/sh
# E082 -- custom derivative rules (P007 Phase 4, item 2).
#
#   1. rules_kernels.rb: two meanings the subset could not write before
#      (LUT interpolation, clamp) accepted through registered rules; every
#      gate (G1..G4, forward gates, G5, RIMPL) must be green.
#   2. rules_check: the INDEPENDENT oracle -- derivatives written from the
#      mathematics + a finite difference of the linked primal, never calling
#      the rule functions (E066: differentials are blind to shared mistakes).
#   3. rules_rejects.rb: the four refusal shapes, each with its obstacle id
#      (norule / norulefwd / fwd1 / O5), on top of methods that all run as
#      ordinary Ruby.
#   4. the corpus runs as plain Ruby (values printed and compared by eye in
#      the Edoc; the gates above are the machine check).
set -e
# Kept as an oracle; it runs only on the owner's instruction (tools/oracle/gate).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tests/grad/e082/oracle/rules/run.orig.sh whole || exit 0
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../../../.." && pwd)
LLVM=/opt/homebrew/opt/llvm/bin
cd "$HERE"
rm -rf out outrj spinel
mkdir -p spinel
cp "$ROOT/tools/grad/spinel/grad.rb" spinel/
cp "$ROOT/tools/grad/spinel/grad_rules.rb" spinel/

echo "== 0: the corpus is ordinary Ruby =="
"$ROOT/vendor/spinel/bin/spinel" rules_kernels.rb -o rules_run \
  --link "$ROOT/tools/grad/rules/spinel_grad_rules_impl.c"
./rules_run

echo "== 1: gradgen accepts the rules kernels (all gates) =="
"$ROOT/tools/grad/spinel-gradgen" rules_kernels.rb -o out > gates.txt
tail -1 gates.txt

echo "== 2: the independent oracle =="
$LLVM/clang -O2 -Wno-everything rules_check.c out/rules_kernels_diff.ll \
  out/rules_impl.o -o out/rules_check -lm \
  -L "$ROOT/vendor/spinel/lib" -lspinel_rt
./out/rules_check > e082_rules_analytic.tsv
tail -1 e082_rules_analytic.tsv

echo "== 3: the reject corpus =="
"$ROOT/vendor/spinel/bin/spinel" rules_rejects.rb -o rejects_run \
  --link "$ROOT/tools/grad/rules/spinel_grad_rules_impl.c"
./rejects_run
"$ROOT/tools/grad/spinel-gradgen" rules_rejects.rb -o outrj --allow-rejects \
  > /dev/null 2>&1 || true
column -t -s"$(printf '\t')" outrj/rejects.tsv 2>/dev/null | cut -c1-140 \
  || cat outrj/rejects.tsv

cp out/gates.tsv e082_rules_gates.tsv
cp out/targets.tsv e082_rules_targets.tsv
cp out/rules_used.tsv e082_rules_used.tsv
cp out/build.tsv e082_rules_build.tsv
cp outrj/rejects.tsv e082_rules_rejects.tsv
cp "$ROOT/tools/grad/rules/rules.tsv" e082_rules_ledger.tsv
echo "done: e082_rules_{gates,targets,used,build,rejects,ledger,analytic}.tsv"
