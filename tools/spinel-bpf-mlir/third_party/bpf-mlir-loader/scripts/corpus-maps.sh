#!/bin/bash
# scripts/corpus-maps.sh — conformance corpus の maps (§12 の map の宣言) を C の照合に通し、want.json と比べる (E003)。
#
#   scripts/corpus-maps.sh [TOOLS_DIR]     # 既定は build/tools
#
# 件数も照合する。PENDING の表の case は「まだ C に無い部分 (理由を名指し)」で、差を数えて別に出す — 表の外の差は失敗。
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="${1:-$HERE/build/tools}"
CORPUS="$HERE/third_party/bpf-mlir/conformance/requirements/maps"
[ -x "$TOOLS/maps_case" ] || { echo "corpus-maps: $TOOLS/maps_case is missing (scripts/build-tools.sh)" >&2; exit 1; }
declare -A PENDING=()
total=0 same=0 fail=0 pending=0
for d in "$CORPUS"/*/; do
  name=$(basename "$d")
  total=$((total + 1))
  want=$(jq -c . "$d/want.json")
  got=$("$TOOLS/maps_case" "$d" | jq -c .) || { echo "FAIL $name: maps_case rc"; fail=$((fail + 1)); continue; }
  if [ "$got" = "$want" ]; then
    same=$((same + 1))
    [ -z "${PENDING[$name]:-}" ] || echo "note: $name is in the PENDING table but matched (review the table)"
  else
    echo "DIFF $name: want $want"
    echo "          got  $got"
    fail=$((fail + 1))
  fi
done
echo "cases: $same / $total same, pending $pending, fail $fail"
[ "$total" -gt 0 ] || { echo "corpus-maps: no cases" >&2; exit 1; }
[ "$fail" -eq 0 ] && [ $((same + pending)) -eq "$total" ]
