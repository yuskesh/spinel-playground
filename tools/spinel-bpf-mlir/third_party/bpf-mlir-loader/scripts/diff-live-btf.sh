#!/bin/bash
# scripts/diff-live-btf.sh — live の caps の vmlinux の BTF と host の問い合わせ (src/caps/live_btf.c・live_host.c) を bpf-mlir の kload
# (test/oracle/cmd/kbtf-live — kload の本文は scripts/gen-kload-copy.sh で機械的に写す) と kernel/core に比べる (E004)。
#
#   scripts/diff-live-btf.sh [TOOLS_DIR]     # 既定 build/tools
#
# この kernel の vmlinux の全ての FUNC (func・func_sig・func_param)・全ての STRUCT の先頭 4 member (struct_field・kfields)・全ての
# btf_trace_* (tracepoint)・kallsyms・arch の問い (正しい答えと変えた答えを混ぜる) の答えの種類と食い違いの文が byte で一致すること。
# root は要らない (/sys/kernel/btf/vmlinux と /proc/kallsyms は誰でも読める)。
set -euo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/diff-live-btf.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="${1:-$HERE/build/tools}"
[ -x "$TOOLS/live_case" ] || { echo "diff-live-btf: $TOOLS/live_case が無い (build-tools.sh)" >&2; exit 1; }
"$HERE/scripts/gen-kload-copy.sh" --check
export TMPDIR="$HERE/build/tmp"
W="$TMPDIR/diff-live-btf"
rm -rf "$W"
mkdir -p "$W"
GO="${GO:-/usr/local/go/bin/go}"
# KBTF_LIVE: host で build した oracle (VM の中 — scripts/run-in-vm.sh)
if [ -n "${KBTF_LIVE:-}" ]; then
  cp "$KBTF_LIVE" "$W/kbtf-live"
else
  (cd "$HERE/test/oracle" && GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=mod "$GO" build -o "$W/kbtf-live" ./cmd/kbtf-live)
fi
"$W/kbtf-live" -gen > "$W/q"
"$W/kbtf-live" "$W/q" > "$W/go"
"$TOOLS/live_case" "$W/q" > "$W/c"
n=$(wc -l < "$W/q")
[ "$n" -gt 1000 ] && [ "$(wc -l < "$W/go")" = "$n" ] && [ "$(wc -l < "$W/c")" = "$n" ] || { echo "diff-live-btf: 件数が合わない ($n)" >&2; exit 1; }
cmp -s "$W/go" "$W/c" || { echo "diff-live-btf: 差" >&2; diff "$W/go" "$W/c" | head -20 >&2 || true; exit 1; }
nd=$(awk -F'\t' '$(NF-1) == "ok" && $NF != "" && $NF != "true" && $NF != "false"' "$W/go" | wc -l)
echo "diff-live-btf: $(uname -r) queries=$n same=$n with_diffs=$nd"
