#!/bin/bash
# scripts/live-diff.sh — E004 の live の差動 (root で — host では sudo、VM の中では root)。ELF ごとに bml-precheck と ebpf-precheck に
# `--live --record` で問い、(A) 記録の答え (種類・値・食い違いの文) と (B) 判定の交差を比べる (scripts/live-one.sh)。
#
#   sudo scripts/live-diff.sh <ELF の一覧 (live-elfs.sh)> <出力の親 dir> <TOOLS_DIR> [権限の組 …]
#
# 権限の組: root・bpf,net_admin・bpf,net_admin,perfmon (既定の 3 つ)。root 以外は uid 1000 に setpriv で落とす (go-bpf-mlir の
# run-nonroot-matrix.sh・bpf-mlir の docs/nonroot.md と同じ形)。出力は <親>/<uname -r>/<組>/ — 各組の summary.txt と ELF ごとの dir。
# 並列 8 (probe は process ごと — cache は process の中だけ)。終わりに出力を SUDO_UID の持ち物に戻す。
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ELFS="${1:?ELF の一覧}"; PARENT="${2:?出力の親}"; T="${3:?TOOLS_DIR}"; shift 3
SETS=("$@"); [ ${#SETS[@]} -gt 0 ] || SETS=(root bpf,net_admin bpf,net_admin,perfmon)
[ "$(id -u)" = 0 ] || { echo "live-diff: root で走らせる" >&2; exit 2; }
K=$(uname -r)
U=${SUDO_UID:-1000}
for s in "${SETS[@]}"; do
  D="$PARENT/$K/$(echo "$s" | tr , +)"
  rm -rf "$D"; mkdir -p "$D"; chown -R "$U" "$PARENT"
  case "$s" in
    root) run=() ;;
    none) run=(setpriv --reuid="$U" --regid="$U" --clear-groups --inh-caps=-all --ambient-caps=-all --bounding-set=-all) ;;
    *) c=$(echo "$s" | sed 's/,/,+/g')
       run=(setpriv --reuid="$U" --regid="$U" --clear-groups --inh-caps=-all,+"$c" --ambient-caps=-all,+"$c" --bounding-set=-all,+"$c") ;;
  esac
  "${run[@]}" sh -c 'id; grep -E "^Cap(Inh|Prm|Eff|Bnd|Amb)" /proc/self/status' > "$D/status.txt" 2>&1
  # 入力の行 "<番号> <ELF>" → live-one.sh <ELF> <作業>/<番号> <T>。作業は process の側の tmpfs (/dev/shm) — VM の中では host と共有の
  # rootfs に uid 1000 の process が書けない (virtme-ng の共有の file system — E004 で見つけた)。終わりに root が D に写す
  WK=$(mktemp -d /dev/shm/live-diff.XXXXXX); chmod 1777 "$WK"
  awk '{printf "%04d %s\n", NR, $0}' "$ELFS" |
    xargs -P 8 -L 1 "${run[@]}" bash -c '"$0" "$4" "$1/$3" "$2"' "$HERE/scripts/live-one.sh" "$WK" "$T" || true
  cp -r "$WK"/. "$D"/; rm -rf "$WK"
  n=0; : > "$D/verdicts.txt"
  while read -r i f; do
    v=$(cat "$D/$i/verdict" 2>/dev/null || echo "missing")
    echo "$i $v $f" >> "$D/verdicts.txt"; n=$((n + 1))
  done < <(awk '{printf "%04d %s\n", NR, $0}' "$ELFS")
  {
    echo "live-diff: kernel=$K caps=$s elfs=$n"
    echo "  (A) 記録: $(awk '{print $2}' "$D/verdicts.txt" | sort | uniq -c | tr '\n' ' ')"
    echo "  (B) C の記録で Go: $(awk '{print $3}' "$D/verdicts.txt" | sort | uniq -c | tr '\n' ' ')"
    echo "  (B) Go の記録で C: $(awk '{print $4}' "$D/verdicts.txt" | sort | uniq -c | tr '\n' ' ')"
    echo "  Go の result: $(awk '{print $5}' "$D/verdicts.txt" | sort | uniq -c | tr '\n' ' ')"
  } | tee "$D/summary.txt"
done
chown -R "$U" "$PARENT"
