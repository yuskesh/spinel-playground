#!/usr/bin/env bash
#
# build_spbpf_schema_check.sh — libspbpf C ABI の in-process consumer を建てる
# (E154)。spinel-llvm の静的 library をリンクするので、spinel-llvm の
# tools/mlir/native/build が先に建っていること。
#
#   出力:   build/tools/spnl_spbpf_schema_check
#   差し替え: SPNL_SPINEL_LLVM_MLIR (native ディレクトリ) / LLVM_CONFIG
#
# 変更が無ければ再リンクしない (mtime 比較)。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

NATIVE="${SPNL_SPINEL_LLVM_MLIR:-}"
LLVM_CONFIG="${LLVM_CONFIG:-/usr/lib/llvm-22/bin/llvm-config}"
SRC="tools/spnl_spbpf_schema_check.c"
OUT="build/tools/spnl_spbpf_schema_check"

CAPI="$NATIVE/build/lib/libSpinelMLIRCAPI.a"
SCHEMA="$NATIVE/build/lib/Target/SpBPF/libSpinelMLIRSpBPFSchema.a"

for f in "$CAPI" "$SCHEMA"; do
  if [ ! -f "$f" ]; then
    echo "error: $f is missing — build the spinel-llvm native tree first" >&2
    exit 1
  fi
done
if [ ! -x "$LLVM_CONFIG" ]; then
  echo "error: llvm-config is missing ($LLVM_CONFIG)" >&2
  exit 1
fi

if [ -x "$OUT" ] && [ "$OUT" -nt "$SRC" ] && [ "$OUT" -nt "$CAPI" ] && [ "$OUT" -nt "$SCHEMA" ]; then
  echo "up to date: $OUT"
  exit 0
fi

mkdir -p build/tools
TMPOBJ="$(mktemp "${TMPDIR:-/tmp}/spnl-spbpf-schema-check.XXXXXX")"
trap 'rm -f "$TMPOBJ"' EXIT

# .c は C としてコンパイルする (C ABI header が C から使えることも兼ねて見る)。
"${CC:-cc}" -O2 -Wall -Wextra -c "$SRC" -I "$NATIVE/include" -o "$TMPOBJ"
# リンクは C++ (libSpinelMLIR* が C++ 実装のため)。
"${CXX:-c++}" "$TMPOBJ" "$CAPI" "$SCHEMA" \
  $("$LLVM_CONFIG" --ldflags --libs support --system-libs) -o "$OUT"

echo "built: $OUT"
