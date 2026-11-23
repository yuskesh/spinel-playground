#!/bin/bash
# E062 version 3: one VM, readonly root and one persistent output export.
set -euo pipefail
[ "$#" = 6 ] || [ "$#" = 7 ] || exit 2
VNG=$1; IMAGE=$2; MANIFEST=$3; GROUP=$4; RUN_ROOT=$5; HELPER=$6
[ "$GROUP" = vm73 ] || { echo 'only vm73 is allowed' >&2; exit 2; }
EXTRA=()
if [ "$#" = 7 ]; then
  [ "$7" = --dry-run ] || exit 2
  EXTRA=(--dry-run)
else
  [ "$(id -u)" = 0 ] || { echo 'approved VM supervisor required' >&2; exit 1; }
fi
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$ROOT/scripts/p152-vm73:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SHA=${E062_EXPECTED_MANIFEST_SHA:?verified parent manifest SHA}
PAYLOAD=$(printf '%q ' "$HELPER" guest --manifest "$MANIFEST" --manifest-sha "$SHA" --cell vm73 --out "$RUN_ROOT")
exec "$VNG" --run "$IMAGE" --user root --cpus 4 --memory 8G --rwdir "$RUN_ROOT" \
  --append "p152=$SHA:vm73" --verbose "${EXTRA[@]}" \
  --exec "env E062_EXPECTED_MANIFEST_SHA=$(printf '%q' "$SHA") $PAYLOAD" < /dev/null
