#!/bin/bash
# One diagnostic VM; no gate/live command exists in this payload.
set -euo pipefail
[ "$#" = 8 ] || exit 2
VNG=$1; IMAGE=$2; MANIFEST=$3; OUT=$4; HELPER=$5; SHA=$6; MODE=$7; ROOT=$8
case "$MODE" in dry) EXTRA=(--dry-run);; run) [ "$(id -u)" = 0 ] || exit 1; EXTRA=();; *) exit 2;; esac
export PATH="$ROOT/scripts/p152-diag:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export E062_DIAG_INITRD="$OUT/initrd"
PAYLOAD=$(printf '%q ' "$HELPER" diag-guest --manifest "$MANIFEST" --manifest-sha "$SHA" --out "$OUT")
exec "$VNG" --run "$IMAGE" --user root --cpus 4 --memory 8G --rwdir "$OUT" \
 --append "ro p152=$SHA:vm718" --verbose "${EXTRA[@]}" --exec "$PAYLOAD" < /dev/null
