#!/bin/bash
# scripts/abi-mojo-target.sh — mojo の面の 1 つの群 (scripts/abi-mojo.tsv — E012 の trace・E013 の tcx …) を 1 つの target (host か VM —
# scripts/run-in-vm.sh) で (root、全て unshare -n の中): 契約の道具 (ASan + UBSan と試験の caps・sanitizer 無しの build — ASan の
# pthread_create の interceptor が thread の mask を上書きするため E012)、表の変異、差動の driver 2 つ (mojo の Go の loader と bml — abi-mojo-diff.sh build)。
#
#   sudo scripts/abi-mojo-target.sh <群> <ELF> <sha> <出力の親> <ASAN_TOOLS_DIR> <MUT_TOOLS_DIR> [<DRV_DIR>]   (DRV が空なら差動は飛ばす)
# 出力は <出力の親>/<kernel>/<群>/{contract.txt, contract-plain.txt, mut-<変異>.txt, diff-mojo.txt, diff-bml.txt, summary.txt}
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
G="${1:?}"; ELF="${2:?}"; SHA="${3:?}"; PARENT="${4:?}"; TA="${5:?}"; TM="${6:?}"; DRV="${7:-}"
[ "$(id -u)" = 0 ] || { echo "abi-mojo-target: root で走らせる" >&2; exit 2; }
row=$(awk -F'\t' -v g="$G" '$1==g' "$HERE/scripts/abi-mojo.tsv")
[ -n "$row" ] || { echo "abi-mojo-target: 群 $G が scripts/abi-mojo.tsv に無い" >&2; exit 2; }
TOOL=$(cut -f2 <<< "$row"); MUTS=$(cut -f5 <<< "$row")
# 7 列目 (任意 — E015): 道具と driver に足す引数。@REPO@ は repo、@ELFDIR@ は ELF の directory、@SHA@<file> は file の sha256
EXTRA=()
for t in $(cut -f7 -s <<< "$row"); do
  t=${t//@REPO@/$HERE}; t=${t//@ELFDIR@/$(dirname "$ELF")}
  case "$t" in @SHA@*) t=$(sha256sum "${t#@SHA@}" | cut -d' ' -f1) ;; esac
  EXTRA+=("$t")
done
K=$(uname -r); O="$PARENT/$K/$G"
rm -rf "$O"; mkdir -p "$O"
rc=0
unshare -n "$TA/$TOOL" "$ELF" "$SHA" "${EXTRA[@]}" > "$O/contract.txt" 2>&1 || rc=1
unshare -n "$TM/$TOOL" "$ELF" "$SHA" "${EXTRA[@]}" > "$O/contract-plain.txt" 2>&1 || rc=1
IFS=';' read -ra ms <<< "$MUTS"
for mf in "${ms[@]}"; do
  BML_MUTANT=${mf%%:*} unshare -n "$TM/$TOOL" "$ELF" "$SHA" "${EXTRA[@]}" > "$O/mut-${mf%%:*}.txt" 2>&1
done
if [ -n "$DRV" ]; then
  unshare -n "$DRV/drv_${G}_mojo" "$ELF" "$SHA" "${EXTRA[@]}" > "$O/diff-mojo.txt" 2>&1 || rc=1
  unshare -n "$DRV/drv_${G}_bml" "$ELF" "$SHA" "${EXTRA[@]}" > "$O/diff-bml.txt" 2>&1 || rc=1
fi
{ echo "kernel $(uname -a)"; cat "$O/contract.txt" "$O/contract-plain.txt" | grep -E ' — (ok|FAIL)$'; } > "$O/summary.txt"
echo "abi-mojo-target $G $K: ok $(grep -c ' — ok$' "$O/summary.txt")、FAIL $(grep -c ' — FAIL$' "$O/summary.txt")"
exit $rc
