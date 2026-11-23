#!/usr/bin/env bash
# Build the product editor as a self-contained native binary. termbox2 and
# libgrapheme are vendored source snapshots; this command never downloads.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/../.." && pwd)
OUT=${1:-"$HERE/build/spinel-vi"}

mkdir -p "$(dirname -- "$OUT")"
test -x "$ROOT/vendor/spinel/bin/spinel" || {
  echo "missing $ROOT/vendor/spinel/bin/spinel; build vendor/spinel first" >&2
  exit 1
}
test -f "$HERE/vendor/termbox2/termbox2.h"
test -f "$HERE/vendor/libgrapheme/gen/character.h"
"$ROOT/vendor/spinel/bin/spinel" "$HERE/editor.rb" -o "$OUT"
printf 'built %s\n' "$OUT"
