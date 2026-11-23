#!/bin/bash
# scripts/diff-usdt.sh — USDT の読みの C (src/req/usdt.c — usdt_case) と Go (requirements.ParseUSDTArg・ReadUSDTPoints・strings.Fields — usdt-oracle) の差動 (E039)。
# 入力: 引数の記述の乱数の綴り (Fields で分けて 1 つずつ)、corpus の bin の全て (stapsdt の note の在るもの・無いもの) と note の section の中だけを壊した変異。
# 許す差は無い (出力の行を byte で比べる)。
#
#   scripts/diff-usdt.sh [SEED] [N] [TOOLS_DIR]     # 既定 1 2000 build/tools (N は綴りの数、note の変異は bin ごとに N/20)
set -euo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/diff-usdt.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SEED="${1:-1}"
N="${2:-2000}"
TOOLS="${3:-$HERE/build/tools}"
export TMPDIR="$HERE/build/tmp"
W="$TMPDIR/diff-usdt"
rm -rf "$W"
mkdir -p "$W/mut"
GO="${GO:-/usr/local/go/bin/go}"
(cd "$HERE/test/oracle" && GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=mod "$GO" build -o "$W/usdt-oracle" ./cmd/usdt-oracle)
BIN="$HERE/third_party/bpf-mlir/conformance/requirements/bin"
"$W/usdt-oracle" gen "$SEED" "$N" > "$W/in.txt"
"$W/usdt-oracle" mutnote "$SEED" $((N / 20)) "$W/mut" "$BIN"/usdt_* > "$W/mut.list"
{ find "$BIN" -type f | LC_ALL=C sort; cat "$W/mut.list"; } | sed 's/^/N /' >> "$W/in.txt"
"$W/usdt-oracle" < "$W/in.txt" > "$W/go.out"
"$TOOLS/usdt_case" < "$W/in.txt" > "$W/c.out"
na=$(grep -c '^A ' "$W/in.txt"); nn=$(grep -c '^N ' "$W/in.txt")
[ "$(grep -c '^[AN] ' "$W/go.out")" -eq $((na + nn)) ] && [ "$(grep -c '^[AN] ' "$W/c.out")" -eq $((na + nn)) ] ||
  { echo "diff-usdt: 件数が合わない" >&2; exit 1; }
if ! cmp -s "$W/go.out" "$W/c.out"; then
  diff "$W/go.out" "$W/c.out" | head -8 >&2 || true # E050: set -e の下の SIGPIPE で後の文を失わない
  echo "diff-usdt: C と Go が違う — $W/go.out と $W/c.out" >&2
  exit 1
fi
echo "diff-usdt: seed=$SEED 綴り $na (field $(grep -c '^  "' "$W/go.out"))・note $nn (点を読めた $(grep -c '^N .* points=' "$W/go.out")、誤り $(grep -c '^N .* err=' "$W/go.out")、開けない $(grep -c 'open-error$' "$W/go.out")) — 全て同じ"
