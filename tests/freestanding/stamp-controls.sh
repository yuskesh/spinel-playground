#!/bin/sh
#
# tests/freestanding/stamp-controls.sh -- the freestanding lanes refuse native
# tools that are not this tree's build (stamps.sh).
#
#   sh tests/freestanding/stamp-controls.sh DIR
#
#   1. this tree's build passes the check;
#   2. an override that copies the build with its stamp (MLIRGEN naming the
#      copy) passes too: overrides keep working when their stamp matches;
#   3. the same copy with one input's digest changed in its stamp:
#      tests/freestanding/run.sh refuses it before any lane runs, naming the
#      tool and the input, and writes no lane log;
#   4. a lane run on its own (e040/run_reject.sh) refuses it the same way,
#      before it writes anything.
#
# Needs the native build (tools/mlir/native/build.sh) and LLVM_PREFIX.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/../.." && pwd)
DIR=${1:?usage: stamp-controls.sh DIR}
BUILT=${SPINEL_CORE_BUILD:-$REPO/tools/mlir/native/build}/bin
[ -x "$BUILT/spinel-fs-emit" ] || { echo "stamp-controls: no spinel-fs-emit in $BUILT (tools/mlir/native/build.sh)" >&2; exit 2; }
: "${LLVM_PREFIX:?set LLVM_PREFIX to the official LLVM 23.1.1}"
mkdir -p "$DIR" || exit 2
K=$DIR/work
[ -e "$K" ] && { echo "stamp-controls: $K exists; give a fresh DIR" >&2; exit 2; }
mkdir -p "$K/same" "$K/stale" "$K/fs" "$K/fs1" || exit 2
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
# stamps MLIRGEN: fs_stamps in a subshell with MLIRGEN set; its exit status
stamps() { (MLIRGEN=$1; . "$HERE/stamps.sh"; fs_stamps) > "$K/stamps.out" 2>&1; echo $?; }

echo "stamp-controls: 1-2. builds this tree's source made"
ok "1. this tree's build passes" "$(stamps "$BUILT/spinel-fs-emit")" 0
cp "$BUILT/spinel-fs-emit" "$BUILT/source-stamp.tsv" "$K/same/" || exit 2
ok "2. a copy with its stamp, named by MLIRGEN, passes" "$(stamps "$K/same/spinel-fs-emit")" 0

echo "stamp-controls: 3-4. a stamp that does not match the tree"
cp "$BUILT/spinel-fs-emit" "$K/stale/" || exit 2
# One input's digest changed, as if the copy were built before that file changed.
awk -F'\t' 'BEGIN { OFS = "\t" } $1 == "tools/mlir/native/lib/Freestanding/Emit.cpp" { $2 = "sha256:" sprintf("%064d", 0) } { print }' \
  "$BUILT/source-stamp.tsv" > "$K/stale/source-stamp.tsv"
ok "the planted stamp differs from the build's in one row" \
   "$(diff "$BUILT/source-stamp.tsv" "$K/stale/source-stamp.tsv" | grep -c '^>')" 1
FS_WORK=$K/fs MLIRGEN=$K/stale/spinel-fs-emit sh "$HERE/run.sh" > "$K/run.out" 2>&1
ok "3. run.sh refuses it" "$?" 1
ok "3. naming the tool and the input that differs" \
   "$(grep -c "kernel $K/stale/spinel-fs-emit was built from other source than this tree's: 1 input(s) differ: tools/mlir/native/lib/Freestanding/Emit.cpp" "$K/run.out")" 1
ok "3. before any lane runs" "$(grep -c 'no lane was run' "$K/run.out")|$(ls "$K/fs" | wc -l | tr -d ' ')" "1|0"
FS_WORK=$K/fs1 MLIRGEN=$K/stale/spinel-fs-emit bash "$HERE/e040/run_reject.sh" > "$K/lane.out" 2>&1
ok "4. a lane on its own refuses it, by name, and writes nothing" \
   "$?|$(grep -c "was built from other source than this tree's" "$K/lane.out")|$(grep -c "e040: the native tools are not this tree's build" "$K/lane.out")|$(ls "$K/fs1" | wc -l | tr -d ' ')" "2|1|1|0"

echo "stamp-controls: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" = 0 ]
