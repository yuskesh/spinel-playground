#!/bin/bash
# scripts/diff-parse.sh — C と Go (bpf-mlir の requirements.Parse — 試験の側の oracle) の Parse の差動 (E002)。
# corpus の parse と cases の requirements (requirements.txt と ELF の section) を種に決定的な変異を作り、判定と拒否の文を比べる。
#
#   scripts/diff-parse.sh [SEED] [N] [TOOLS_DIR]     # 既定 1 200 build/tools
#
# 件数も照合する (比べた数が変異の数と同じで 0 でない)。
set -euo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/diff-parse.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SEED="${1:-1}"
N="${2:-200}"
TOOLS="${3:-$HERE/build/tools}"
export TMPDIR="$HERE/build/tmp"
W="$TMPDIR/diff-parse"
rm -rf "$W"
mkdir -p "$W/seeds" "$W/mut"
GO="${GO:-/usr/local/go/bin/go}"
(cd "$HERE/test/oracle" && GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=mod "$GO" build -o "$W/parse-oracle" ./cmd/parse-oracle &&
  GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=mod "$GO" build -o "$W/mutate" ./cmd/mutate)

C="$HERE/third_party/bpf-mlir/conformance/requirements"
i=0
for f in "$C"/parse/*/requirements.txt "$C"/cases/*/requirements.txt; do
  cp "$f" "$W/seeds/$(printf '%03d' $i).txt"; i=$((i + 1))
done
for o in "$C"/cases/*/object.bpf.o; do
  "${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/llvm-objcopy" -O binary --only-section=.ebpf_requirements "$o" "$W/seeds/$(printf '%03d' $i).txt" 2>/dev/null || continue
  [ -s "$W/seeds/$(printf '%03d' $i).txt" ] && i=$((i + 1))
done
"$W/mutate" -seed "$SEED" -n "$N" -out "$W/mut" "$W"/seeds/*.txt
find "$W/seeds" "$W/mut" -name '*.txt' | LC_ALL=C sort > "$W/list"
xargs -a "$W/list" "$W/parse-oracle" > "$W/go.out"
xargs -a "$W/list" "$TOOLS/parse_case" -m > "$W/c.out"
total=$(wc -l < "$W/list")
ngo=$(wc -l < "$W/go.out")
nc=$(wc -l < "$W/c.out")
echo "diff-parse: seed=$SEED seeds=$i inputs=$total go=$ngo c=$nc"
echo "  go の判定の内訳: $(cut -f2 "$W/go.out" | grep -o '"rule":"[a-z_]*"\|"accept":true\|"untyped":true' | sort | uniq -c | tr '\n' ' ')"
[ "$total" -gt 0 ] && [ "$ngo" -eq "$total" ] && [ "$nc" -eq "$total" ] || { echo "diff-parse: 件数が合わない" >&2; exit 1; }
if ! diff "$W/go.out" "$W/c.out" > "$W/diff.txt"; then
  echo "diff-parse: C と Go が違う — $(grep -c '^<' "$W/diff.txt") 件 ($W/diff.txt)" >&2
  head -6 "$W/diff.txt" >&2
  exit 1
fi
echo "diff-parse: $total / $total same (判定・行・行の種類・規則・拒否の文)"
