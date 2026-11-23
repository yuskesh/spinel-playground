#!/bin/sh
# E076 demo B -- calibrate a bot scorer's weights with the gradient of its loss,
# CPU only. Ported from spinel-llvm 463d49dd
# docs/experiments/results/E076/demoB/build.sh, and the run its README names
# (`./calib 2000 3000`).
#
# Checks: gradgen passes G1-G4 on the loss; the calibration program builds
# against the gradient object and runs; and calibration does what the demo
# claims, on the held-out set: accuracy and F1 both rise over the shipped
# weights (calib.rb prints both deltas).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../../env.sh"
fresh
cd "$OUT"
if "$GRADGEN" score_learn.rb -o out > gates.tsv 2>&1; then rc=0; else rc=1; fi
result gradgen_g1_g4 $rc "$(tail -1 gates.tsv)"
[ $rc = 0 ] || { cat gates.tsv; exit 1; }
cp out/score_learn_grad.gen.rb .
"$SPINEL" calib.rb -o calib --link out/score_learn_grad.o
if ./calib 2000 3000 > calibration.tsv; then rc=0; else rc=1; fi
result calib_runs $rc "$(sed -n 's/^steps_taken\t/steps /p' calibration.tsv)"
for k in test_accuracy_delta test_f1_delta; do
  d=$(sed -n "s/^$k\t//p" calibration.tsv)
  ruby -e 'exit(Float(ARGV[0]) > 0 ? 0 : 1)' "${d:-0}" && ok=0 || ok=1
  result "$k" $ok "${d:-(missing)}"
done
cat "$OUT/result.tsv"
! grep -q '	FAIL	' "$OUT/result.tsv"
