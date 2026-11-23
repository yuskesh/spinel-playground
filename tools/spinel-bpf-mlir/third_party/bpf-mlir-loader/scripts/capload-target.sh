#!/bin/bash
# scripts/capload-target.sh — E019: 権限の組 (root・bpf+net_admin・bpf+perfmon・none) × fixture (e19fe・e19fx・e19kp・e19xp) の load の kind と
# 権限の hint を bml と mojo の Go の loader (capload_diff の 2 つの driver) で 1 つの target (host か VM — scripts/run-in-vm.sh) で (root、unshare -n の中、
# root 以外は setpriv で uid と cap を落とす — live-diff.sh と同じ形)。
#
#   sudo scripts/capload-target.sh <出力の親> <DRV_DIR> <ELF_DIR>     (ELF_DIR に e19{fe,fx,kp,xp}.bpf.o と .sha)
set -uo pipefail
PARENT="${1:?}"; DRV="${2:?}"; ED="${3:?}"
[ "$(id -u)" = 0 ] || { echo "capload-target: root で走らせる" >&2; exit 2; }
K=$(uname -r); O="$PARENT/$K"
rm -rf "$O"; mkdir -p "$O"
U=${SUDO_UID:-1000}
for s in root bpf,net_admin bpf,perfmon none; do
  case "$s" in
    root) run=() ;;
    none) run=(setpriv --reuid="$U" --regid="$U" --clear-groups --inh-caps=-all --ambient-caps=-all --bounding-set=-all) ;;
    *) c=$(echo "$s" | sed 's/,/,+/g')
       run=(setpriv --reuid="$U" --regid="$U" --clear-groups --inh-caps=-all,+"$c" --ambient-caps=-all,+"$c" --bounding-set=-all,+"$c") ;;
  esac
  for f in fe fx kp xp; do
    for side in mojo bml; do
      unshare -n "${run[@]}" "$DRV/drv_capload_$side" "$s/$f" "$ED/e19$f.bpf.o" "$(cat "$ED/e19$f.sha")" >> "$O/$side.txt" 2>> "$O/$side.msg"
    done
  done
done
if cmp -s "$O/mojo.txt" "$O/bml.txt"; then echo "capload-target $K: $(wc -l < "$O/bml.txt") 行が一致 — ok"; else diff "$O/mojo.txt" "$O/bml.txt"; echo "capload-target $K: 違う — FAIL"; exit 1; fi
