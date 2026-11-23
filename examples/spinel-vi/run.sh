#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN=${SPINEL_VI_BIN:-"$HERE/build/spinel-vi"}

if [ ! -x "$BIN" ]; then
  "$HERE/build.sh" "$BIN"
fi
# The product is interactive by default.  Gates set fake explicitly so that
# their normalized screen logs never depend on a user's terminal emulator.
exec env SPINEL_VI_BACKEND="${SPINEL_VI_BACKEND:-termbox2}" "$BIN" "$@"
