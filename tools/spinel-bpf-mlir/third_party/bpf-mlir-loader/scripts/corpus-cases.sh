#!/bin/bash
# scripts/corpus-cases.sh — conformance corpus の cases を C の照合 (記録した caps) に通し、want.json と比べる (E002)。
#
#   scripts/corpus-cases.sh [TOOLS_DIR]     # 既定は build/tools
#
# 件数も照合する。PENDING の表の case は「まだ C に無い部分 (理由を名指し)」で、差を数えて別に出す — 表の外の差は失敗。
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="${1:-$HERE/build/tools}"
CORPUS="$HERE/third_party/bpf-mlir/conformance/requirements/cases"
[ -x "$TOOLS/check_case" ] || { echo "corpus-cases: $TOOLS/check_case is missing (scripts/build-tools.sh)" >&2; exit 1; }
# 未実装の名指しの表 — case の名前: 理由 (E008 — uprobe の DWARF の読み)
declare -A PENDING=(
  # (空 — E008 で uprobe の DWARF の 6 case を閉じた)
)
total=0 same=0 fail=0 pending=0
for d in "$CORPUS"/*/; do
  name=$(basename "$d")
  total=$((total + 1))
  want=$(jq -c . "$d/want.json")
  got=$("$TOOLS/check_case" "$d" | jq -c .) || { echo "FAIL $name: check_case rc"; fail=$((fail + 1)); continue; }
  if [ "$got" = "$want" ]; then
    same=$((same + 1))
    [ -z "${PENDING[$name]:-}" ] || echo "note: $name is in the PENDING table but matched (review the table)"
  elif [ -n "${PENDING[$name]:-}" ]; then
    # 向きの確認 (E002 の受理の条件): C は止める側だけ — result は target_rejected、want に無い C の Unmet は止める uprobearg_unknown だけ、
    # C に無い want の Unmet は uprobearg・uprobearg_abi・uprobearg_abi_unknown (DWARF が要る判定 — 版 4 の E306 を含む) だけ。緩む向き (C が通す・止めない Unknown) は失敗
    dir_ok=$(jq -n --argjson w "$want" --argjson g "$got" '
      ($g.result == "target_rejected")
      and ([$g.unmet[] | select(. as $u | ($w.unmet | index([$u])) == null)] | all(.kind == "uprobearg_unknown" and .blocks_load))
      and ([$w.unmet[] | select(. as $u | ($g.unmet | index([$u])) == null)] | all(.kind == "uprobearg" or .kind == "uprobearg_abi" or .kind == "uprobearg_abi_unknown"))')
    if [ "$dir_ok" != true ]; then
      echo "DIFF $name: the PENDING difference is not on the stopping side (${PENDING[$name]}): want $want got $got"
      fail=$((fail + 1))
      continue
    fi
    echo "PENDING $name (${PENDING[$name]}; C is on the stopping side): want $(jq -r .result <<< "$want") got $(jq -r .result <<< "$got")"
    pending=$((pending + 1))
  else
    echo "DIFF $name: want $want"
    echo "          got  $got"
    fail=$((fail + 1))
  fi
done
echo "cases: $same / $total same, pending $pending, fail $fail"
[ "$total" -gt 0 ] || { echo "corpus-cases: no cases" >&2; exit 1; }
[ "$fail" -eq 0 ] && [ $((same + pending)) -eq "$total" ]
