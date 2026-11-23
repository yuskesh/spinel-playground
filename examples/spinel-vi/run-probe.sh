#!/usr/bin/env bash
# E097 Phase 0 terminal-ABI probe runner; fake is deterministic by default.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN=${1:-"$HERE/build/spinel-vi-probe"}
if [ "$#" -gt 0 ]; then shift; fi
if [ ! -x "$BIN" ]; then "$HERE/build-probe.sh" "$BIN"; fi
exec env SPINEL_VI_BACKEND="${SPINEL_VI_BACKEND:-fake}" "$BIN" "$@"
