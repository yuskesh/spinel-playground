#!/bin/sh
# tools/census/run_census_gate.sh — a standing gate that detects boxing regressions
#
#   tools/census/run_census_gate.sh            # vendor corpus + doom
#   SPINEL_LLVM_SHL_DEFER=1 tools/census/... # measure with the flag set
#
# The standing gate (over 3,000 programs) looks only at **output**, so it catches
# no regression to "correct but slow". This closes that blind spot (one such regression has already slipped through).
set -eu
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(cd -- "$HERE/../.." && pwd)
C="$HERE/spinel-boxing-census"
W="${TMPDIR:-/tmp}/spinel-census"
mkdir -p "$W"
rc=0

echo "== vendor corpus"
ruby "$C" take "$W/vendor_now.tsv" > /dev/null
ruby "$C" gate "$HERE/baseline/vendor_bd2d276a.tsv" "$W/vendor_now.tsv" || rc=1

echo "== doom"
ruby "$C" take "$W/doom_now.tsv" "$ROOT"/doom/bin/*.rb > /dev/null
ruby "$C" gate "$HERE/baseline/doom.tsv" "$W/doom_now.tsv" || rc=1

[ "$rc" = 0 ] && echo "---- census gate: PASS" || echo "---- census gate: FAIL"
exit "$rc"
