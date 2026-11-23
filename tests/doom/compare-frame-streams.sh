#!/bin/sh
#
# tests/doom/compare-frame-streams.sh — two per-tic frame-hash TSVs agree, over
# the tics that were ASKED FOR.
#
#   compare-frame-streams.sh <a.tsv> <b.tsv> <ntics>
#
# Separate from tests/doom/interactive.sh so that the rule can be controlled on
# its own.  The rule is not "the two files are equal": two files truncated the
# same way are equal and have compared almost nothing.  Both must carry exactly
# the requested tics, keyed 0..ntics-1, with no gap at either end, and only then
# are they compared byte for byte.
set -eu

A="${1:?usage: compare-frame-streams.sh <a.tsv> <b.tsv> <ntics>}"
B="${2:?usage: compare-frame-streams.sh <a.tsv> <b.tsv> <ntics>}"
N="${3:?usage: compare-frame-streams.sh <a.tsv> <b.tsv> <ntics>}"

fail() { echo "frame-streams: FAIL $*" >&2; exit 1; }

check_one() { # $1 path  $2 label
  f="$1"; label="$2"
  [ -f "$f" ] || fail "$label: no such file: $f"
  [ -s "$f" ] || fail "$label: $f is empty"
  rows=$(grep -vc '^#' "$f" || true)
  [ "$rows" = "$N" ] || fail "$label: $rows rows, expected exactly $N (the requested tic count)"
  # Keys must be 0..N-1 exactly: present, unique, in order.  Checked rather than
  # inferred from the count, because N rows can still be the wrong N tics.
  bad=$(awk -F'\t' -v n="$N" '
    !/^#/ {
      if ($1 != i) { printf "row %d has gametic %s, expected %d\n", i, $1, i; bad = 1; exit }
      i++
    }
    END { if (!bad && i != n) printf "ended at gametic %d, expected %d\n", i, n }
  ' "$f")
  [ -z "$bad" ] || fail "$label: $bad"
}

check_one "$A" "first"
check_one "$B" "second"

if cmp -s "$A" "$B"; then
  echo "frame-streams: OK ($N tics, keys 0..$((N - 1)), identical)"
  exit 0
fi
echo "frame-streams: FAIL the two streams differ" >&2
diff -u "$A" "$B" 2>&1 | head -20 | sed 's/^/    /' >&2
exit 1
