#!/bin/sh
# G5 controls -- what spinel-gradgen's fast-math gate counts in an adjoint.
#
# G5 refuses an adjoint that carries a fast-math flag (E079 s4.3), except
# nnan/ninf on an operation whose operands are all integer-to-float
# conversions in the same function: LLVM's instcombine proves those flags after
# Enzyme, and they change no value. adjoints.ll holds one hand-written shape
# per function; expect.tsv says what the scan must count in each. The scan is
# the gate's own (g5_scan, loaded from spinel-gradgen), not a copy.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../../env.sh"
fresh
cd "$OUT"
RUBY=${RUBY:-ruby}
"$RUBY" "$HERE/scan.rb" "$GRADGEN" "$HERE/adjoints.ll" > scan.tsv
tail -n +2 "$HERE/expect.tsv" | while IFS="$(printf '\t')" read -r fn want_s want_i want_f; do
  got=$(awk -F'\t' -v f="$fn" '$1==f {print $2 "\t" $3 "\t" $4}' scan.tsv)
  [ "$got" = "$(printf '%s\t%s\t%s' "$want_s" "$want_i" "$want_f")" ]
  result "g5_$fn" $? "expected sites=$want_s int_derived=$want_i flags=$want_f, got $(printf '%s' "${got:-(not scanned)}" | tr '\t' ' ')"
done
n=$(tail -n +2 scan.tsv | wc -l | tr -d ' ')
[ "$n" = "$(tail -n +2 "$HERE/expect.tsv" | wc -l | tr -d ' ')" ]; result g5_functions $? "$n adjoints scanned"
cat "$OUT/result.tsv"
! grep -q '	FAIL	' "$OUT/result.tsv"
