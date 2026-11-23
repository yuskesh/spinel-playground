#!/usr/bin/env bash
# Compatibility spelling for the product entry point.  Prefer ./build.sh.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OUT=${1:-"$HERE/build/spinel-vi-editor"}

exec "$HERE/build.sh" "$OUT"
