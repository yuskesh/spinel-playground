#!/usr/bin/env bash
#
# tools/realtime/test/run.sh -- pin spinel-rtcheck's behaviour.
#
#   tools/realtime/test/run.sh [--update]
#
# One compile of test/cases.rb, every case as an entry, in both modes.  The
# verdict column is compared against expected.tsv; --update rewrites it.
#
# The table deliberately contains as many ACCEPTS as REFUSALS: "it says no to
# everything" is the failure mode a soundness tool cannot detect on itself.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RT="$(dirname "$HERE")"
OUT="${TMPDIR:-/tmp}/rtcheck-test"
mkdir -p "$OUT"

ENTRIES=(pure_add pure_loop ary_get ary_length ivar_free
         str_build ary_new_each_call ary_push ary_set raise_guard loop_break)
ARGS=()
for e in "${ENTRIES[@]}"; do ARGS+=(--entry "$e"); done

: > "$OUT/got.tsv"
for mode in strict abort; do
  flag=()
  [ "$mode" = abort ] && flag=(--allow-abort)
  "$RT/spinel-rtcheck" "$HERE/cases.rb" --int-overflow wrap "${flag[@]}" \
      "${ARGS[@]}" 2>/dev/null | tail -n +2 \
    | awk -F'\t' -v m="$mode" '{print m "\t" $2 "\t" $1}' >> "$OUT/got.tsv"
done

if [ "${1:-}" = "--update" ]; then
  cp "$OUT/got.tsv" "$HERE/expected.tsv"
  echo "updated $HERE/expected.tsv"
  exit 0
fi

if diff -u "$HERE/expected.tsv" "$OUT/got.tsv" > "$OUT/diff.txt"; then
  n=$(wc -l < "$OUT/got.tsv" | tr -d ' ')
  a=$(grep -c 'PROVEN' "$OUT/got.tsv")
  echo "rtcheck test: $n rows match ($a accepted, $((n - a)) refused)"
  exit 0
fi
echo "rtcheck test: MISMATCH"
cat "$OUT/diff.txt"
exit 1
