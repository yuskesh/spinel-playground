#!/bin/bash
# scripts/diff-kfield-cycle.sh — E018 (bpf-mlir E326): 作った BTF (循環・共有・自己参照・循環の無い入れ子 — test/oracle/cmd/kbtf-live -cyclebtf)
# の kfields の答えを C (live_case — BML_TEST_VMLINUX) と Go (kbtf-live — kernel/core.CheckKFields) で byte で比べる。root 不要。
#
#   scripts/diff-kfield-cycle.sh [TOOLS_DIR]     # 既定 build/tools
set -euo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/diff-kfield-cycle.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="${1:-$HERE/build/tools}"
W="$HERE/build/tmp/diff-kfield-cycle"
rm -rf "$W"; mkdir -p "$W"
(cd "$HERE/test/oracle" && GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=mod "${GO:-/usr/local/go/bin/go}" build -o "$W/kbtf-live" ./cmd/kbtf-live)
"$W/kbtf-live" -cyclebtf "$W/cycle.btf"
for q in "cyc x u32" "cyc y u32" "cyc nope u32" "shared z u32" "shared nope u32" "selfref w u32" "selfref nope u32" "plain q u32" "plain nope u32" \
  "cyc x u32;shared nope u32;plain q u32"; do
  printf 'kfields\t%s\n' "$(printf '%s' "$q" | sed 's/\([a-z]*\) \([a-z]*\) \([a-z0-9]*\)/p \1 \2 \3/g')"
done > "$W/q"
BML_TEST_VMLINUX="$W/cycle.btf" "$W/kbtf-live" "$W/q" > "$W/go"
BML_TEST_VMLINUX="$W/cycle.btf" timeout 30 "$TOOLS/live_case" "$W/q" > "$W/c"
if ! cmp -s "$W/go" "$W/c"; then
  diff "$W/go" "$W/c"
  echo "diff-kfield-cycle: 違う — FAIL"
  exit 1
fi
echo "diff-kfield-cycle: 問い $(wc -l < "$W/q") が一致 (循環の注 $(grep -c 'met the same anonymous type twice' "$W/c")) — ok"
