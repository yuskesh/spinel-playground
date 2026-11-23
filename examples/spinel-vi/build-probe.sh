#!/usr/bin/env bash
# E097 Phase 0 terminal-ABI probe.  It intentionally does not build editor.rb.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/../.." && pwd)
OUT=${1:-"$HERE/build/spinel-vi-probe"}
mkdir -p "$(dirname -- "$OUT")"
exec "$ROOT/vendor/spinel/bin/spinel" "$HERE/app.rb" -o "$OUT"
