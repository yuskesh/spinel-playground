#!/bin/bash
# scripts/bml-corpus.sh — P021 E085: bpf-mlir の conformance corpus (spinel の bpf-mlir の submodule — bml の入れ子の bpf-mlir と同じ commit) の cases を
# bml の C の照合 (check_case — 記録した caps) に通し、want.json と比べる (bml の scripts/corpus-cases.sh と同じ比べ方 — bml の tree の script は使わない)。
#
#   scripts/bml-corpus.sh [TOOLS_DIR (既定 build/bml/tools — scripts/prep-bmlcheck.sh)]
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="${1:-$HERE/build/bml/tools}"
CORPUS="$HERE/third_party/bpf-mlir/conformance/requirements/cases"
[ -x "$TOOLS/check_case" ] || { echo "bml-corpus: $TOOLS/check_case is missing (run scripts/prep-bmlcheck.sh)" >&2; exit 1; }
total=0 same=0 fail=0
for d in "$CORPUS"/*/; do
  name=$(basename "$d")
  total=$((total + 1))
  want=$(jq -c . "$d/want.json")
  got=$("$TOOLS/check_case" "$d" | jq -c .) || { echo "FAIL $name: check_case rc"; fail=$((fail + 1)); continue; }
  if [ "$got" = "$want" ]; then
    same=$((same + 1))
    echo "$name same"
  else
    echo "DIFF $name: want $want"
    echo "          got  $got"
    fail=$((fail + 1))
  fi
done
echo "cases: $same / $total same, fail $fail"
[ "$total" -gt 0 ] && [ "$fail" -eq 0 ]
