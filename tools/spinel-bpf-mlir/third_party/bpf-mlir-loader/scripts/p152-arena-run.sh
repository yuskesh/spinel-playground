#!/bin/bash
# E062: run is explicit; default/missing mode never starts a target.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
exec "$HERE/build/tools/p152-plan" run "$@"
