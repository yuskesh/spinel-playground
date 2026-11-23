#!/bin/sh
# examples/ghostty-terminal/build.sh OUT -- builds the page into OUT/web, and
# the native bridge to a shell on this machine into OUT/bridge.
#
#   LLVM_PREFIX, WASI_SYSROOT, WASI_BUILTINS   as tools/wasm/spinel-wasm reads them
#   GHOSTTY_DIR   a Ghostty checkout with zig-out/lib/libghostty-vt.a (see README)
#   naga and spirv-val on PATH
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
: "${1:?usage: build.sh OUT}"
: "${LLVM_PREFIX:?set LLVM_PREFIX}"
: "${WASI_SYSROOT:?set WASI_SYSROOT}"
: "${GHOSTTY_DIR:?set GHOSTTY_DIR to a built Ghostty checkout}"
mkdir -p "$1/web" "$1/shader"
OUT=$(CDPATH= cd -- "$1" && pwd)
cd "$HERE"
for shader in quad glyph; do
  "$ROOT/tools/shader/spinel-rb2spv" "shader/$shader.rb" --out "$OUT/shader" --res 16 >/dev/null
  spirv-val "$OUT/shader/$shader/shader.spv"
  cp "$OUT/shader/$shader/shader.wgsl" "$OUT/web/$shader.wgsl"
done
"$LLVM_PREFIX/bin/clang" --target=wasm32-wasip1 --sysroot="$WASI_SYSROOT" \
  -I"$GHOSTTY_DIR/include" -O2 -c host.c -o "$OUT/host.o"
# Some of libghostty-vt's escape handlers take over 64 KiB of stack, wasm-ld's default.
STACK_BYTES=4194304
"$ROOT/tools/wasm/spinel-wasm" shell.rb -o "$OUT/web/shell.wasm" -I . \
  --link "$OUT/host.o" --link "$GHOSTTY_DIR/zig-out/lib/libghostty-vt.a" \
  --link=-zstack-size=$STACK_BYTES
cp web/index.html web/main.mjs "$ROOT/tools/wasm/wasi_shim.mjs" "$OUT/web/"
"$ROOT/vendor/spinel/bin/spinel" bridge.rb -o "$OUT/bridge"
