#!/usr/bin/env bash
set -euo pipefail
[[ $# == 9 ]] || exit 64
VNG=$1 IMAGE=$2 MANIFEST=$3 OUT=$4 HELPER=$5 SHA=$6 MODE=$7 REPO=$8 QSHA=$9
case "$MODE" in
 dry) EXTRA=(--dry-run) ;;
 run) [[ $EUID == 0 ]] || exit 64; EXTRA=() ;;
 *) exit 64 ;;
esac
[[ ! -e "$OUT/initrd" && ! -L "$OUT/initrd" ]] || exit 1
export E064_HELPER="$HELPER" E064_MANIFEST="$MANIFEST" E064_SHA="$SHA" E064_OUT="$OUT" E064_QSHA="$QSHA"
export E064_INITRD="$OUT/initrd" PYTHONUNBUFFERED=1
export PATH="$REPO/scripts/p152-launch:$PATH"
printf -v PAYLOAD '%q ' "$HELPER" launch-guest --manifest "$MANIFEST" --manifest-sha "$SHA" --out "$OUT"
exec "$VNG" --run "$IMAGE" --user root --cpus 4 --memory 8G --rwdir "$OUT" \
 --qemu "$REPO/scripts/p152-launch-qemu.sh" --append "ro p152=$SHA:vm718" \
 --verbose "${EXTRA[@]}" --exec "$PAYLOAD" </dev/null
