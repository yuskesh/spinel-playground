#!/bin/bash
# scripts/load-target.sh — E005 の 1 つの target (host か VM — scripts/run-in-vm.sh) の全て (root で): 権限の組ごとに ELF の一覧を照合と
# guard 付きで load (load_case) し段を数え、libbpf の feature と C の live の答えの表 (feat_case)、負の対照 (load-controls.sh)、
# process の状態 (live-state.sh の load)。
#
#   sudo scripts/load-target.sh <ELF の一覧> <出力の親> <TOOLS_DIR> <MUT_TOOLS_DIR>
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ELFS="${1:?}"; PARENT="${2:?}"; T="${3:?}"; TM="${4:?}"
[ "$(id -u)" = 0 ] || { echo "load-target: root で走らせる" >&2; exit 2; }
export PATH="$PATH:/usr/sbin:/sbin"
K=$(uname -r); O="$PARENT/$K"; U=${SUDO_UID:-1000}
rm -rf "$O"; mkdir -p "$O"
S="$O/summary.txt"
{ echo "kernel $(uname -a)"; for b in load_case load_case_wrap feat_case; do echo "bin_sha256_$b $(sha256sum < "$T/$b" | cut -d' ' -f1)"; done; } > "$S"
for s in root bpf,net_admin bpf,net_admin,perfmon none; do
  case "$s" in
    root) run=() ;;
    none) run=(setpriv --reuid="$U" --regid="$U" --clear-groups --inh-caps=-all --ambient-caps=-all --bounding-set=-all) ;;
    *) c=$(echo "$s" | sed 's/,/,+/g'); run=(setpriv --reuid="$U" --regid="$U" --clear-groups --inh-caps=-all,+"$c" --ambient-caps=-all,+"$c" --bounding-set=-all,+"$c") ;;
  esac
  d="$O/$(echo "$s" | tr , +)"; mkdir -p "$d"
  WK=$(mktemp -d /dev/shm/load-target.XXXXXX); chmod 1777 "$WK"   # VM の共有の rootfs に非 root は書けない (E004)
  "${run[@]}" "$T/feat_case" > "$WK/feat.txt" 2>/dev/null
  xargs -a "$ELFS" "${run[@]}" "$T/load_case" > "$WK/load.txt" 2>/dev/null
  cp "$WK"/*.txt "$d"/; rm -rf "$WK"
  {
    echo "load: caps=$s elfs=$(wc -l < "$d/load.txt")"
    echo "  段: $(awk -F'\t' '{print $2"/"$3}' "$d/load.txt" | sort | uniq -c | tr '\n' ' ')"
    echo "  guard の停止: $(awk -F'\t' '$3!="ok" && $3!="-" && $3!="libbpf" {print $3}' "$d/load.txt" | sort | uniq -c | tr '\n' ' ')"
    echo "  feat (live/libbpf): $(awk -F'\t' '$1=="btf"{print ($3=="true" && $5=="supported") || ($3!="true" && $5=="missing") ? "agree" : "DISAGREE:"$2}' "$d/feat.txt" | sort | uniq -c | tr '\n' ' ') libbpf の外の feature の missing: $(awk -F'\t' '$1=="libbpf" && $3=="missing"{print $2}' "$d/feat.txt" | tr '\n' ' ')"
  } >> "$S"
done
"$HERE/scripts/load-controls.sh" "$T" "$TM" > "$O/controls.txt" 2>&1; echo "controls rc=$? $(tail -1 "$O/controls.txt")" >> "$S"
"$HERE/scripts/live-state.sh" "$ELFS" "$T" "$O/state" load > "$O/state.txt" 2>&1; echo "load-state rc=$? $(tail -1 "$O/state.txt")" >> "$S"
chown -R "$U" "$PARENT"
cat "$S"
