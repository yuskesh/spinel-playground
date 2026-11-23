#!/bin/bash
# scripts/diff-dwarf.sh — E008 の差動: C の DWARF の reader (test/dwarf/dwarf_case) と Go の oracle (test/oracle/cmd/dwarf-oracle — bpf-mlir の
# dwarfParams の複写) を同じ binary の列に当て、出力を byte で比べる。binary: bpf-mlir の uprobe の fixture の全て (C・C++・Rust の lang・
# DWARF 無し・Go (zlib で圧縮)・E306)、この repo の道具 (gcc -g・clang -g の DWARF 5)、Go の binary (oracle 自身・ebpf-precheck)。
#
#   scripts/diff-dwarf.sh [TOOLS_DIR]     # 既定は build/tools (dwarf_case と ebpf-precheck)
set -uo pipefail
# Spinel Extended: an oracle; it runs only with ALLOW_ORACLE=1 (tests/ORACLES.tsv).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../../.." && pwd)/tools/oracle/gate" tools/spinel-bpf-mlir/third_party/bpf-mlir-loader/scripts/diff-dwarf.sh whole || exit 0
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="${1:-$HERE/build/tools}"
W="$HERE/build/tmp/diff-dwarf"
mkdir -p "$W"
"$HERE/scripts/gen-dwarf-copy.sh" --check || exit 1 # E055: oracle は uprobe.go の機械的な写し
(cd "$HERE/test/oracle" && GOWORK=off GOTOOLCHAIN=local GOFLAGS=-mod=mod "${GO:-/usr/local/go/bin/go}" build -o "$W/dwarf-oracle" ./cmd/dwarf-oracle) || exit 1
BM="$HERE/third_party/bpf-mlir"
# P001 の E008 の完成条件: clang / gcc × DWARF 4 / 5 × -O0 / -O2 (bpf-mlir の uprobe の fixture の source — 引数の型の種類を持つ)
mkdir -p "$W/var"
for cc in gcc /opt/llvm-23.1.1/bin/clang; do
  for dv in 4 5; do
    for o in 0 2; do
      "$cc" -g -gdwarf-$dv -O$o -o "$W/var/fixture-$(basename "$cc")-dwarf$dv-O$o" "$BM/kernel/uprobe/fixture/fixture.c" || exit 1
    done
  done
done
mapfile -t BINS < <({ ls "$BM"/conformance/requirements/bin/*; find "$BM/kernel/uprobe/fixture" -type f -perm -u+x -path '*/bin*'
  for t in dwarf_case check_case abi_case ebpf-precheck; do echo "$HERE/build/tools/$t"; done
  for t in dwarf_case abi_up; do echo "$HERE/build/tools-asan/$t"; done
  echo "$W/dwarf-oracle"
  ls "$HERE"/docs/experiments/results/E008/fuzz-*.elf "$W"/var/*; } | LC_ALL=C sort -u) # fuzz が見つけた入力 (E008 — varint の underflow)
"$TOOLS/dwarf_case" "${BINS[@]}" > "$W/c.txt" 2>&1
"$W/dwarf-oracle" "${BINS[@]}" > "$W/go.txt" 2>&1
if ! cmp -s "$W/c.txt" "$W/go.txt"; then
  diff "$W/go.txt" "$W/c.txt" | head -40
  echo "diff-dwarf: 差 $(diff "$W/go.txt" "$W/c.txt" | grep -c '^[<>]') 行 — FAIL"
  exit 1
fi
echo "diff-dwarf: binary ${#BINS[@]}・行 $(wc -l < "$W/c.txt") (subprogram $(grep -c $'\t' "$W/c.txt")) が一致 — ok"
# E057 (bpf-mlir E559 — 形式 18): 全ての仮引数を ptr として問う (DIE を直接歩く綴り — dwarfPointerSpelling)
"$TOOLS/dwarf_case" -ptr "${BINS[@]}" > "$W/c-ptr.txt" 2>&1
"$W/dwarf-oracle" -ptr "${BINS[@]}" > "$W/go-ptr.txt" 2>&1
if ! cmp -s "$W/c-ptr.txt" "$W/go-ptr.txt"; then
  diff "$W/go-ptr.txt" "$W/c-ptr.txt" | head -40
  echo "diff-dwarf: ptr の綴りの差 $(diff "$W/go-ptr.txt" "$W/c-ptr.txt" | grep -c '^[<>]') 行 — FAIL"
  exit 1
fi
echo "diff-dwarf: ptr の綴り — 仮引数 $(grep -o $'\t"[^"]*":' "$W/c-ptr.txt" | wc -l) が一致 ($(grep -oE ':(ptr|non-pointer|ptr\(depth[^	]*\))?($|	)' "$W/c-ptr.txt" | sed 's/	//' | sort | uniq -c | tr '\n' ' '))"
