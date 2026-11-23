#!/bin/bash
# scripts/diff-elf.sh — C の ELF の読み (bml_req_from_elf) と Go (elf.NewFile → Section → Data → Parse) の差動 (E002)。
# corpus の cases の ELF を種に決定的な byte の変異を作り、段 (open・no_section・data・parse・ok) と parse の判定を比べる。
# 許す差は無い (E002 の除外の表 c_strict:e_version は v0.12.1 で解消)。
#
#   scripts/diff-elf.sh [SEED] [N] [TOOLS_DIR]     # 既定 1 200 build/tools
set -euo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/diff-elf.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SEED="${1:-1}"
N="${2:-200}"
TOOLS="${3:-$HERE/build/tools}"
export TMPDIR="$HERE/build/tmp"
W="$TMPDIR/diff-elf"
rm -rf "$W"
mkdir -p "$W/mut"
GO="${GO:-/usr/local/go/bin/go}"
(cd "$HERE/test/oracle" && GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=mod "$GO" build -o "$W/elf-oracle" ./cmd/elf-oracle &&
  GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=mod "$GO" build -o "$W/mutate" ./cmd/mutate)
find "$HERE/third_party/bpf-mlir/conformance/requirements/cases" -name '*.bpf.o' | LC_ALL=C sort > "$W/seeds"
xargs -a "$W/seeds" "$W/mutate" -elf -seed "$SEED" -n "$N" -out "$W/mut"
{ cat "$W/seeds"; find "$W/mut" -name '*.txt' | LC_ALL=C sort; } > "$W/list"
xargs -a "$W/list" "$W/elf-oracle" > "$W/go.out"
xargs -a "$W/list" "$TOOLS/elf_case" > "$W/c.out"
total=$(wc -l < "$W/list")
[ "$total" -gt 0 ] && [ "$(wc -l < "$W/go.out")" -eq "$total" ] && [ "$(wc -l < "$W/c.out")" -eq "$total" ] ||
  { echo "diff-elf: 件数が合わない" >&2; exit 1; }
echo "diff-elf: seed=$SEED inputs=$total go の段: $(cut -f2 "$W/go.out" | sort | uniq -c | tr '\n' ' ')"
# 除外の表は空 (bpf-mlir v0.12.1 の E296 から Go も e_version を全 4 byte で見る — E002 の c_strict:e_version は解消)。全ての差は失敗。
# C の印 c_strict:e_version は「C の e_version の拒否」の名指しとして残す — Go も open なら同じ段として数える。
paste "$W/go.out" "$W/c.out" | awk -F'\t' -v W="$W" '
  $1 != $4 { print "path mismatch" > W "/bad.txt"; bad++; next }
  $6 == "c_strict:e_version" && $5 == "open" && $2 == "open" { same++; next }
  $2 == $5 && $3 == $6 { same++; next }
  { print $0 > W "/bad.txt"; bad++ }
  END { printf "diff-elf: inputs=%d same=%d bad=%d\n", NR, same, bad; exit bad > 0 }' ||
  { echo "diff-elf: C と Go が違う — $W/bad.txt" >&2; head -4 "$W/bad.txt" >&2; exit 1; }
