#!/bin/sh
# E076 demo A -- learn a separable 3-tap filter on the CPU with the gradient
# Enzyme built from filter_learn.rb, then apply the learned window through the
# tensor lane. Ported from spinel-llvm 463d49dd
# docs/experiments/results/E076/demoA/{build.sh,run.sh}.
#
# Phase 1 checks: gradgen passes G1-G4; train recovers the taps of the filter it
# generated its target with (worst tap error below 1e-9; E076 recorded 5.8e-15).
# Phase 2 checks, on every device this host has (local-sync and local-task, and
# metal on macOS): apply runs with the learned and with the exact taps, and every
# device returns the same bytes, the learned window's the same as the exact one's.
#
# Phase 2 needs IREE_SRC, IREE_BUILD and IREE_COMPILE, as examples/image does.
# Local changes: the image is the tracked img.pgm (spinel-llvm regenerated it with
# mkimage.py, which was not imported); apply.rb's comparison with an f64 Ruby
# implementation runs only with SPINEL_ORACLE=1.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../../env.sh"
fresh
cp "$HERE/img.pgm" "$OUT/"
cd "$OUT"
STEPS=${STEPS:-20000}

# ---- phase 1: learn ----------------------------------------------------------
if (mkdir -p grad && "$GRADGEN" filter_learn.rb -o grad > gates.txt 2>&1); then rc=0; else rc=1; fi
result gradgen_g1_g4 $rc "$(tail -1 gates.txt)"
[ $rc = 0 ] || { cat gates.txt; exit 1; }
cp grad/filter_learn_grad.gen.rb .
"$SPINEL" train.rb -o train --link grad/filter_learn_grad.o
if ./train img.pgm learned.txt "$STEPS" > learn.tsv; then rc=0; else rc=1; fi
result train_runs $rc "$(sed -n 's/^steps_taken\t/steps /p' learn.tsv)"
e=$(sed -n 's/^worst_tap_abs_err\t//p' learn.tsv)
ruby -e 'exit(Float(ARGV[0]) < 1e-9 ? 0 : 1)' "${e:-1}" && ok=0 || ok=1
result taps_recovered $ok "worst_tap_abs_err ${e:-(missing)}"

# ---- phase 2: apply through the tensor lane ----------------------------------
# examples/image/env.sh finds its directory from $0, so it is sourced by a shell
# whose $0 is an image example script.
OUT="$OUT" SPINEL="$SPINEL" sh -c '
  . "$(dirname "$0")/../env.sh"
  set -e
  cd "$OUT"
  cp "$SURFACE" spinel/
  "$MLIRGEN" kernels.rb --tensor -o demoA.mlir --emit-table sp_tensor_table.h \
      --emit-ruby kernels.gen.rb --iree-compile "$IREE_COMPILE" --vmfb demoA
  "$CC" -O2 -c "$SHIM" -o sp_tensor_shim.o $IREE_CFLAGS -I"$OUT"
  "$SPINEL" apply.rb -o apply --link sp_tensor_shim.o $IREE_LINK
' "$ROOT/examples/image/filter/build.sh" > phase2_build.txt 2>&1 && rc=0 || rc=1
result tensor_build $rc "$(tail -1 phase2_build.txt)"
[ $rc = 0 ] || { tail -20 phase2_build.txt; exit 1; }

printf '0.25 0.5 0.25\n0.25 0.5 0.25\n' > truth.txt
DEVICES="local-sync local-task"
[ "$(uname -s)" = Darwin ] && DEVICES="$DEVICES metal"
for d in $DEVICES; do
  v=demoA_cpu.vmfb; [ "$d" = metal ] && v=demoA_metal.vmfb
  ./apply "$d" "$v" img.pgm learned.txt . > "apply_learned_$d.tsv" && rc=0 || rc=1
  result "apply_learned_$d" $rc "hash $(sed -n 's/^hash\t//p' "apply_learned_$d.tsv")"
  ./apply "$d" "$v" img.pgm truth.txt - > "apply_truth_$d.tsv" && rc=0 || rc=1
  result "apply_truth_$d" $rc "hash $(sed -n 's/^hash\t//p' "apply_truth_$d.tsv")"
done
for d in $DEVICES; do
  [ "$d" = local-sync ] && continue
  cmp -s out_local-sync.pgm "out_$d.pgm"; result "bytes_local-sync_eq_$d" $? "out_$d.pgm"
done
a=$(sed -n 's/^hash\t//p' apply_learned_local-sync.tsv)
b=$(sed -n 's/^hash\t//p' apply_truth_local-sync.tsv)
[ -n "$a" ] && [ "$a" = "$b" ]; result learned_eq_exact $? "learned $a, exact $b"
cat "$OUT/result.tsv"
! grep -q '	FAIL	' "$OUT/result.tsv"
