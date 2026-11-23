#!/bin/bash
# scripts/e56-fixtures.sh — E056 の fixture を OUT に (gcc): full (.symtab と .dynsym)・dynsym (--strip-all — .dynsym だけ)・twoaddr (.symtab に同じ名前の
# FUNC を別の address で足した — .symtab と .dynsym で食い違う)・twosym (.dynsym に出さず .symtab だけで 2 つの address)
#
#   scripts/e56-fixtures.sh OUT
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
O="${1:?OUT}"
OC=/opt/llvm-23.1.1/bin/llvm-objcopy
rm -rf "$O"; mkdir -p "$O"
cd "$O"
# -g と build ID: uretprobe の呼び出し規約 (E397) は DWARF が要る — dynsym には分けた file (full.debug — E055) を target の debug で渡す
gcc -O0 -g -Wl,--build-id -rdynamic -o full "$HERE/test/abi/fixture/e56/e56.c"
"$OC" --only-keep-debug full full.debug
"$OC" --strip-all full dynsym
"$OC" --add-symbol e56_fn=.text:0x4,function,global full twoaddr
gcc -O0 -o local "$HERE/test/abi/fixture/e56/e56.c"
"$OC" --add-symbol e56_fn=.text:0x4,function,global local twosym
sha256sum full dynsym twoaddr twosym
