#!/bin/bash
# E062 preparation only, no sudo/VM/BPF operation.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
[ "$(id -u)" != 0 ] || { echo 'prepare must run unprivileged' >&2; exit 1; }
exec "$HERE/build/tools/p152-plan" prepare --root "$HERE" --out "${1:?FRESH_OUT}"
