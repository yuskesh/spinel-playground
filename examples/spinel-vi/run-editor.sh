#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Compatibility spelling for the product entry point. Prefer ./run.sh.
if [ "$#" -gt 0 ] && [ -x "$1" ]; then
  export SPINEL_VI_BIN=$1
  shift
fi
exec "$HERE/run.sh" "$@"
