#!/bin/bash
# scripts/build-uprobe-fixtures.sh — P020 E080: uprobe の target の C の fixture を build し、同じ directory の SHA256SUMS を書く (mojo-bpf-mlir P022 E085 の写し)。
#   scripts/build-uprobe-fixtures.sh           fixture を build し直して SHA256SUMS を書く (commit する binary)
#   scripts/build-uprobe-fixtures.sh --check   別の directory に source を写して build し、commit した binary と byte 一致を確かめる (書き換えない)
# 再現のため: clang は $LLVM_PREFIX の 23.1.1、source の directory の path を DWARF から消す (-ffile-prefix-map・-fdebug-compilation-dir)。
# -fno-inline-functions と noinline — 呼び出しが inline されると probe が発火しない (go-bpf-mlir R005 §2.4)。
set -euo pipefail
cd "$(dirname "$0")/.."
LLVM_PREFIX="${LLVM_PREFIX:-/opt/llvm-23.1.1}"
CC="$LLVM_PREFIX/bin/clang"
# fixture の一覧: <出力の path>:<source の path> (SHA256SUMS は出力の directory ごと)
FIXTURES="internal/frontend/testdata/uprobe/target/cfix:internal/frontend/testdata/uprobe/target/cfix.c internal/frontend/testdata/uprobe/target/gfix:internal/frontend/testdata/uprobe/target/gfix.c internal/frontend/testdata/uprobe/target/mfix:internal/frontend/testdata/uprobe/target/mfix.c internal/frontend/testdata/uprobe/target/pfix:internal/frontend/testdata/uprobe/target/pfix.c examples/greetwatch/target/greeter:examples/greetwatch/target/greeter.c"
build() { # src out
  local src=$1 out=$2 dir; dir=$(cd "$(dirname "$src")" && pwd)
  (cd "$dir" && "$CC" -g -O1 -fno-inline-functions -ffile-prefix-map="$dir"=. -fdebug-compilation-dir=. -o "$out" "$(basename "$src")")
}
if [ "${1:-}" = "--check" ]; then
  mkdir -p build/tmp
  T=$(mktemp -d "$(pwd)/build/tmp/uprobe-fixture-check.XXXXXX"); trap 'rm -rf "$T"' EXIT
  rc=0
  for e in $FIXTURES; do
    IFS=: read -r out src <<< "$e"
    mkdir -p "$T/$(dirname "$src")"; cp "$src" "$T/$src"
    build "$T/$src" "$T/$out.rebuilt"
    if cmp -s "$T/$out.rebuilt" "$out"; then echo "ok $out (rebuilt in $T — byte-identical)"; else echo "!! $out differs when rebuilt elsewhere"; rc=1; fi
  done
  exit $rc
fi
dirs=""
for e in $FIXTURES; do
  IFS=: read -r out src <<< "$e"
  build "$src" "$(pwd)/$out"
  dirs="$dirs $(dirname "$out")"
  echo "built $out $(sha256sum "$out" | cut -d' ' -f1)"
done
for d in $(echo $dirs | tr ' ' '\n' | sort -u); do
  (cd "$d" && for f in *; do if [ -f "$f" ] && [ -x "$f" ]; then sha256sum "$f"; fi; done > SHA256SUMS)
done
