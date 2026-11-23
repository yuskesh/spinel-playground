#!/bin/bash
# Root supervisor owns and bounds this process; guest status is independently checked.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo 'VM entry requires approved root supervisor' >&2; exit 1; }
[ "$#" = 6 ] || { echo 'VNG IMAGE MANIFEST GROUP RUN_ROOT HELPER required' >&2; exit 2; }
VNG=$1; IMAGE=$2; MANIFEST=$3; GROUP=$4; RUN_ROOT=$5; HELPER=$6
SHA=${E062_EXPECTED_MANIFEST_SHA:?verified parent manifest SHA}
PAYLOAD=$(printf '%q ' "$HELPER" guest --manifest "$MANIFEST" --manifest-sha "$SHA" --cell "$GROUP" --out "$RUN_ROOT")
ENVS=""
for name in KBTF_ORACLE MUTATE KBTF_LIVE STRARG_LIVE; do
  [ -z "${!name:-}" ] || ENVS="$ENVS $(printf '%q' "$name=${!name}")"
done
exec "$VNG" --run "$IMAGE" --rw --user root --cpus 4 --memory 4G \
  --append "p152=$SHA:$GROUP" \
  --exec "env E062_EXPECTED_MANIFEST_SHA=$(printf '%q' "$SHA")$ENVS $PAYLOAD; rc=\$?; printf 'E062_GUEST_RC=%s\\n' \"\$rc\"; exit \"\$rc\"" < /dev/null
