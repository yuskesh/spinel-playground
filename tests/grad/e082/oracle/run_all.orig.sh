#!/bin/sh
# E082 -- run every permanent gate, in dependency order, and collect the
# tables.  Each stage's run.sh is independently rerunnable; this is the
# one-command form.
set -e
# Kept as an oracle; it runs only on the owner's instruction (tools/oracle/gate).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)/tools/oracle/gate" tests/grad/e082/oracle/run_all.orig.sh whole || exit 0
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

sh hvp/run.sh
sh rules/run.sh
sh searchgate/run.sh          # needs rules/out
bash nonreg/run_nonreg.sh

mkdir -p tables
cp hvp/e082_hvp_gates.tsv hvp/e082_hvp_targets.tsv \
   hvp/e082_hvp_fwd_targets.tsv hvp/e082_hvp_build.tsv \
   hvp/e082_hvp_analytic.tsv hvp/e082_newton.tsv hvp/e082_newton_gates.tsv \
   rules/e082_rules_gates.tsv rules/e082_rules_targets.tsv \
   rules/e082_rules_used.tsv rules/e082_rules_build.tsv \
   rules/e082_rules_rejects.tsv rules/e082_rules_ledger.tsv \
   rules/e082_rules_analytic.tsv \
   searchgate/e082_searchgate_biteproof.tsv \
   searchgate/e082_searchgate_e080.tsv \
   searchgate/e082_searchgate_gates.tsv \
   nonreg/nonreg.tsv \
   tables/
mv tables/nonreg.tsv tables/e082_nonreg.tsv

echo
echo "== E082 gate accounting =="
total=0
for f in tables/e082_hvp_gates.tsv tables/e082_newton_gates.tsv \
         tables/e082_newton.tsv tables/e082_rules_gates.tsv \
         tables/e082_hvp_analytic.tsv tables/e082_rules_analytic.tsv \
         tables/e082_searchgate_biteproof.tsv tables/e082_searchgate_gates.tsv \
         tables/e082_searchgate_e080.tsv \
         tables/e082_nonreg.tsv tables/e082_rules_rejects.tsv; do
  n=$(( $(grep -vc '^#' "$f") - 1 ))
  total=$((total + n))
  printf '%-44s %5d rows\n' "$(basename "$f")" "$n"
done
echo "total gate rows: $total"
