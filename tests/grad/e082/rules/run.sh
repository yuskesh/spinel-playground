#!/bin/sh
# E082 rules -- custom derivative rules (tools/grad/rules). Ported from
# spinel-llvm 463d49dd docs/experiments/results/E082/rules/run.sh.
#
# Checks: the kernels and the reject corpus run as ordinary Ruby; gradgen
# accepts rules_kernels.rb with every gate green (G1-G4, the forward gates, G5
# and the rule implementations); and it refuses each declaration of
# rules_rejects.rb with the obstacle the corpus header names (expect.tsv).
#
# Not run: rules_check.c, the independent derivatives written from the
# mathematics (an oracle, kept in ../oracle/).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../../env.sh"
fresh
cd "$OUT"
IMPL=$ROOT/tools/grad/rules/spinel_grad_rules_impl.c
"$SPINEL" rules_kernels.rb -o rules_run --link "$IMPL"
./rules_run > run.txt 2>&1 && rc=0 || rc=1
result kernels_run_as_ruby $rc "$(wc -l < run.txt) lines"
"$GRADGEN" rules_kernels.rb -o out > gates.txt 2>&1 && rc=0 || rc=1
result gradgen_all_gates $rc "$(tail -1 gates.txt)"
[ $rc = 0 ] || { cat gates.txt; exit 1; }

"$SPINEL" rules_rejects.rb -o rejects_run --link "$IMPL"
./rejects_run > rejects_run.txt 2>&1 && rc=0 || rc=1
result rejects_run_as_ruby $rc "$(wc -l < rejects_run.txt) lines"
"$GRADGEN" rules_rejects.rb -o outrj --allow-rejects > rejects.txt 2>&1 || true
tail -n +2 "$HERE/expect.tsv" | while IFS="$(printf '\t')" read -r t want; do
  got=$(awk -F'\t' -v t="$t" '$1==t {print $2}' outrj/rejects.tsv)
  [ "$got" = "$want" ]; result "reject_$t" $? "expected $want, got ${got:-(not refused)}"
done
acc=$(awk 'NR>1' outrj/targets.tsv 2>/dev/null | wc -l | tr -d ' ')
[ "$acc" = 0 ]; result rejects_none_accepted $? "$acc accepted"
cat "$OUT/result.tsv"
! grep -q '	FAIL	' "$OUT/result.tsv"
