#!/usr/bin/env sh
# tools/census/emit_c_hashes.sh — hash the generated C of a corpus, one program at a time, and list the hashes.
#
#   tools/census/emit_c_hashes.sh <out.tsv> [corpus...]
#
# An instrument for measuring rule 3 of the vendor patches (SPINEL_LLVM_PATCHES.md), "byte-identical
# when the flag is unset". Patches L1 to L7 each ran this by hand, but the procedure was
# recorded nowhere, so it was extracted with L8.
#
#   1) take with the patched binary → after.tsv
#   2) remove the patch, rebuild, take → before.tsv
#   3) diff before.tsv after.tsv    ← a single line of output breaks rule 3
#
# Without a corpus, vendor/spinel's test/*.rb + benchmark/*.rb (= 3,053 programs).
# **Environment variables are passed through, so running with a flag set does produce a diff** (that is the control).
set -eu
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(cd -- "$HERE/../.." && pwd)
SPINEL=${SPINEL:-$ROOT/vendor/spinel/bin/spinel}
OUT=${1:?usage: emit_c_hashes.sh <out.tsv> [corpus...]}
shift || true

[ -x "$SPINEL" ] || { echo "no spinel at $SPINEL" >&2; exit 2; }

if [ "$#" -gt 0 ]; then
  set -- "$@"
else
  # shellcheck disable=SC2046
  set -- $(ls "$ROOT"/vendor/spinel/test/*.rb "$ROOT"/vendor/spinel/benchmark/*.rb 2>/dev/null)
fi

: > "$OUT"
n=0; bad=0
for f in "$@"; do
  # -S prints the generated C to stdout. A program that does not compile is recorded as "-"
  # and **not skipped silently** (so that the number of programs run is known afterwards).
  if h=$("$SPINEL" "$f" -S 2>/dev/null | shasum -a 256 | cut -d' ' -f1); then
    printf '%s\t%s\n' "${f#"$ROOT"/}" "$h" >> "$OUT"
  else
    printf '%s\t-\n' "${f#"$ROOT"/}" >> "$OUT"
    bad=$((bad + 1))
  fi
  n=$((n + 1))
done
echo "emit_c_hashes: $n -> $OUT ($bad could not be emitted)"
