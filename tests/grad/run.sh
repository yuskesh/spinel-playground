#!/bin/sh
# tests/grad/run.sh -- the host gradient cases, in one run.
#
# Ported from spinel-llvm 463d49dd (docs/experiments/results/E076 and E082):
# E076 twoexits, rejects, demoB and demoA (the lane-entrance measurement, the
# obstacle corpus, and two demos that learn with the gradient), and E082 rules,
# hvp and searchgate (custom derivative rules, the forward vocabulary with
# Newton-CG, and the search gate). Each case writes result.tsv under $GRAD_WORK;
# its exit status is its verdict.
#
# Requires what env.sh names (LLVM_PREFIX, ENZYME) and, for demoA's second
# phase, what examples/image/env.sh names (IREE_SRC, IREE_BUILD, IREE_COMPILE).
# Nothing is skipped. Oracles do not run here: they are under each lane's
# oracle/ directory (README.md).
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GRAD_WORK=${GRAD_WORK:-${TMPDIR:-/tmp}/spinel-grad}
export GRAD_WORK
mkdir -p "$GRAD_WORK"

failed=""
t_all=$(date +%s)
for c in e076/twoexits e076/rejects e076/demoB e076/demoA \
         e082/rules e082/hvp e082/searchgate gates/g5; do
  t0=$(date +%s)
  log=$GRAD_WORK/$(echo "$c" | tr / -).log
  if sh "$HERE/$c/run.sh" > "$log" 2>&1; then rc=0; else rc=1; fi
  res=$GRAD_WORK/$(echo "$c" | tr / -)/result.tsv
  p=$(grep -c '	PASS	' "$res" 2>/dev/null); f=$(grep -c '	FAIL	' "$res" 2>/dev/null)
  echo "$c: ${p:-0} pass, ${f:-0} fail [rc $rc, $(( $(date +%s) - t0 )) s]"
  if [ "$rc" != 0 ]; then
    failed="$failed $c"
    tail -5 "$log" | sed 's/^/    /'
  fi
done
echo
echo "total wall: $(( $(date +%s) - t_all )) s"
if [ -n "$failed" ]; then echo "run: failed:$failed"; exit 1; fi
echo "run: every case passed"
