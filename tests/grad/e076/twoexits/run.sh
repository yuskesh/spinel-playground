#!/bin/sh
# E076 twoexits -- the lane-entrance measurement: one `spinel -S` emission gives
# both the program's own function and its adjoint. Ported from spinel-llvm
# 463d49dd docs/experiments/results/E076/twoexits/run.sh.
#
# Checks: gradgen passes G1-G4 on `twin`; the object exports only the three
# gradient symbols; and twin.rb, which calls the method both as its own compiled
# Ruby and through the gradient object's primal, sees all 25 points bit-equal.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../../env.sh"
fresh
cd "$OUT"
if "$GRADGEN" twin_run.rb -o out > gates.txt 2>&1; then rc=0; else rc=1; fi
result gradgen_g1_g4 $rc "$(tail -1 gates.txt)"
[ $rc = 0 ] || { cat gates.txt; exit 1; }
cp out/twin_run_grad.gen.rb twin_grad.gen.rb
exports=$("$LLVM_PREFIX/bin/llvm-nm" --defined-only -g out/twin_run_grad.o | awk '{print $NF}' | sort | tr '\n' ,)
[ "$exports" = "spg_grad_twin,spg_sig_twin,spg_val_twin," ]; result object_exports $? "$exports"
"$SPINEL" twin.rb -o twin --link out/twin_run_grad.o
./twin > twin.txt
same=$(sed -n 's/^bitwise_equal\t//p' twin.txt)
[ "$same" = 25 ]; result two_exits_bit_equal $? "bitwise_equal $same of 25"
cat "$OUT/result.tsv"
! grep -q '	FAIL	' "$OUT/result.tsv"
