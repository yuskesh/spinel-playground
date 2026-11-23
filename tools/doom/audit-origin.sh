#!/bin/sh
#
# tools/doom/audit-origin.sh — re-derive the manifest's ORIGINAL digests from a
# read-only predecessor checkout.
#
#   DOOM_SRC_GIT=/path/to/spinel-llvm tools/doom/audit-origin.sh
#
# This is an AUDIT and is deliberately separate from the build and the test
# suite: it needs a second repository, and nothing that builds or tests DOOM
# here may depend on one.  tests/doom/run.sh never calls it.  Use it to confirm
# that the imported bytes are the bytes the manifest says they are, and that
# every file recorded as unmodified really is.
#
# The predecessor checkout is read through `git show` only; it is not modified.
set -eu

. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/sha256.sh"

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
MANIFEST="$ROOT/tests/doom/manifest.tsv"
REV="${DOOM_SRC_REV:-f8ad13c6d9dc990b116ba1c842c7881232f29585}"
SRC="${DOOM_SRC_GIT:?set DOOM_SRC_GIT to a read-only predecessor checkout}"

n=0; same=0; diffd=0
while IFS='	' read -r kind opath obytes osha lpath lbytes lsha modified; do
  case "$kind" in ''|\#*) continue ;; esac
  tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT INT TERM
  git -C "$SRC" show "$REV:$opath" > "$tmp" 2>/dev/null || {
    echo "audit-origin: $opath is absent at $REV" >&2; exit 1; }
  gb=$(wc -c < "$tmp" | tr -d ' \t'); gs=$(sp_sha256 "$tmp")
  rm -f "$tmp"
  [ "$gb" = "$obytes" ] || { echo "audit-origin: $opath is $gb bytes at $REV, manifest says $obytes" >&2; exit 1; }
  [ "$gs" = "$osha" ]   || { echo "audit-origin: $opath has sha256 $gs at $REV, manifest says $osha" >&2; exit 1; }
  if [ "$gs" = "$lsha" ]; then same=$((same + 1)); else diffd=$((diffd + 1)); fi
  n=$((n + 1))
done < "$MANIFEST"

echo "audit-origin: $n originals re-derived at $REV; $same byte-identical to the import, $diffd changed"
