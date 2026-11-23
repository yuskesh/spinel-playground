#!/usr/bin/env bash
# Exercise the observable POSIX adapter contracts under WASI, without an oracle.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -eu
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
SP=${SPINEL_DIR:-$REPO/vendor/spinel}
: "${LLVM_PREFIX:?set LLVM_PREFIX}" "${WASI_SYSROOT:?set WASI_SYSROOT}" "${WASI_BUILTINS:?set WASI_BUILTINS}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/spinel-posix-shims.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
FLAGS=(--target=wasm32-wasip1 --sysroot="$WASI_SYSROOT" -O2
  -ffunction-sections -fdata-sections -Wno-comment
  -DSP_NO_SIGNALS -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_MMAN
  -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_GETPID
  -I"$SP/lib/wasi")
for source in "$HERE/fixtures/wasm-posix-shims.c" "$REPO/tools/wasm/wasi_posix.c" "$REPO/tools/wasm/stubs.c"; do
  "$LLVM_PREFIX/bin/clang" "${FLAGS[@]}" -c "$source" -o "$TMP/$(basename "$source" .c).o"
done
"$LLVM_PREFIX/bin/wasm-ld" --gc-sections "$WASI_SYSROOT/lib/wasm32-wasip1/crt1-command.o" \
  "$TMP/wasm-posix-shims.o" "$TMP/wasi_posix.o" "$TMP/stubs.o" \
  -L"$WASI_SYSROOT/lib/wasm32-wasip1" -lc "$WASI_BUILTINS" -o "$TMP/check.wasm"
node --experimental-wasm-exnref - "$TMP/check.wasm" <<'JS'
const fs = require('node:fs');
const { WASI } = require('node:wasi');
const wasi = new WASI({ version: 'preview1', args: [], env: {}, preopens: {} });
WebAssembly.instantiate(fs.readFileSync(process.argv[2]), {
  wasi_snapshot_preview1: wasi.wasiImport,
}).then(({ instance }) => wasi.start(instance)).catch(error => {
  console.error(error);
  process.exitCode = 1;
});
JS
