#!/bin/bash
# scripts/live-target.sh — E004 の 1 つの target (host か VM) の全て (root で): live の差動 (4 つの権限の組)・process の状態・vmlinux の
# 問い合わせの差動・kernel の BTF の reader の差動。host と VM で同じ手順 (VM は scripts/run-in-vm.sh の中で)。
#
#   sudo KBTF_ORACLE=… MUTATE=… KBTF_LIVE=… scripts/live-target.sh <ELF の一覧> <出力の親> <TOOLS_DIR>
#
# 出力: <親>/<uname -r>/ — 各段の log と summary.txt (段ごとの 1 行)。
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ELFS="${1:?}"; PARENT="${2:?}"; T="${3:?}"; MATRIX="${4:-}" # MATRIX: live-matrix.sh の一覧 (任意)
[ "$(id -u)" = 0 ] || { echo "live-target: root で走らせる" >&2; exit 2; }
export PATH="$PATH:/usr/sbin:/sbin"
K=$(uname -r)
O="$PARENT/$K"
mkdir -p "$O"
S="$O/summary.txt"
{
  echo "kernel $(uname -a)"
  echo "vmlinux_btf_sha256 $(sha256sum < /sys/kernel/btf/vmlinux | cut -d' ' -f1)"
  echo "unprivileged_bpf_disabled $(cat /proc/sys/kernel/unprivileged_bpf_disabled)"
  for b in bml-precheck ebpf-precheck live_case kbtf_case; do echo "bin_sha256_$b $(sha256sum < "$T/$b" | cut -d' ' -f1)"; done
} > "$S"
"$HERE/scripts/live-diff.sh" "$ELFS" "$PARENT" "$T" root bpf,net_admin bpf,net_admin,perfmon none > "$O/live-diff.log" 2>&1
grep -E "^live-diff|\(A\)|\(B\)|result" "$O/live-diff.log" >> "$S"
if [ -n "$MATRIX" ]; then
  "$HERE/scripts/live-diff.sh" "$MATRIX" "$PARENT/matrix" "$T" root bpf,net_admin bpf,net_admin,perfmon none > "$O/live-matrix.log" 2>&1
  sed "s/^live-diff:/live-matrix:/" "$O/live-matrix.log" | grep -E "^live-matrix|\(A\)|\(B\)|result" >> "$S"
fi
"$HERE/scripts/live-state.sh" "$ELFS" "$T" "$O/state" > "$O/live-state.log" 2>&1; echo "live-state rc=$? $(tail -1 "$O/live-state.log")" >> "$S"
"$HERE/scripts/diff-live-btf.sh" "$T" > "$O/diff-live-btf.log" 2>&1; echo "diff-live-btf rc=$? $(tail -1 "$O/diff-live-btf.log")" >> "$S"
"$HERE/scripts/diff-kbtf.sh" 1 3 "$T" > "$O/diff-kbtf.log" 2>&1; echo "diff-kbtf rc=$? $(tail -1 "$O/diff-kbtf.log")" >> "$S"
# E053: tpfield / sysarg の strptr・strarray の分類の差動 (root の本当の tracefs と非 root の形 — Go の oracle は STRARG_LIVE、無ければ
# diff-strarg.sh の既定の build/oracles/strarg-live — 段を条件で飛ばさない)
for m in r n; do
  "$HERE/scripts/diff-strarg.sh" $m "$T" "$O/strarg-$m" > "$O/diff-strarg-$m.log" 2>&1; echo "diff-strarg-$m rc=$? $(grep '^diff-strarg' "$O/diff-strarg-$m.log" | tr '\n' ' ')" >> "$S"
done
chown -R "${SUDO_UID:-1000}" "$HERE/build/tmp/diff-live-btf" "$HERE/build/tmp/diff-kbtf" 2>/dev/null
chown -R "${SUDO_UID:-1000}" "$PARENT"
cat "$S"
# E053 (the bpf-mlir coordinator's instruction): check the list of expected stages against the summary lines — a missing stage or a stage with rc ≠ 0 gives rc 1, never silently
rc=0
for st in live-diff live-state diff-live-btf diff-kbtf diff-strarg-r diff-strarg-n ${MATRIX:+live-matrix}; do
  grep -q "^$st[: ]" "$S" || { echo "live-target: 段 $st の行が summary に無い" >&2; rc=1; }
done
grep -E '^[a-z-]+ rc=[1-9]' "$S" >&2 && rc=1
exit $rc
