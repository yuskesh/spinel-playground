#!/bin/sh
#
# tests/lowering/locations.sh -- the lowering locates each node in its own
# file (docs/core/lowering-inputs.md, defect (i)).
#
#   sh tests/lowering/locations.sh DIR
#
# fixtures/locations: main.rb declares f and requires helper.rb, whose g
# (lines 5-7) f calls. spinel-fs-emit's MLIR must place
#
#   1. g's function and its `*` in helper.rb, at helper.rb's own lines
#      (5:0, 6:2), and f's in main.rb (4:0, and the `+` at 5:9);
#   2. no location in the emitter's temp directory, where it analyses copies;
#   3. with the source named through a directory from another working
#      directory, the same locations under that directory;
#   4. control: main.rb with g written in it, a single file, has every
#      location in main.rb.
#
# 5. The CORE kernel's failure sites take the same locations, but a CORE root
#    that requires another file is refused before analysis (it analyses a
#    snapshot of the root alone); this is checked, so a change that admits
#    one is seen here.
#
# Needs the native build (SPINEL_CORE_BUILD, default tools/mlir/native/build)
# and the reader (SPINEL_TYPEDUMP, default tools/contract/build/spinel-typedump),
# each held to this tree by its source stamp; LLVM_PREFIX for the kernel's clang.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIR=${1:?usage: locations.sh DIR}
BIN=${SPINEL_CORE_BUILD:-$ROOT/tools/mlir/native/build}/bin
READER=${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}
CLANG=${CLANG:-${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/clang}
PROFILE=$ROOT/tools/freestanding/profiles/cortex-m33-zephyr.yaml
FIX=$ROOT/tests/lowering/fixtures/locations
for t in "$BIN/spinel-fs-emit" "$BIN/spinel-core-kernel" "$READER" "$CLANG"; do
  [ -x "$t" ] || { echo "locations: no executable at $t" >&2; exit 2; }
done
. "$ROOT/tools/test/source-stamp.sh"
source_stamp kernel "$BIN/spinel-fs-emit"
source_stamp reader "$READER"
mkdir -p "$DIR" || exit 2
W=$DIR/work
[ -e "$W" ] && { echo "locations: $W exists; give a fresh DIR" >&2; exit 2; }
mkdir -p "$W/src/spinel" && cp "$FIX/main.rb" "$FIX/helper.rb" "$W/src/" &&
  cp "$ROOT/tools/freestanding/spinel/freestanding.rb" "$W/src/spinel/" || exit 2
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
# emit CWD SOURCE TAG: spinel-fs-emit from CWD; the MLIR in W/TAG.mlir
emit() {
  (cd "$1" && TMPDIR="$W/tmp" "$BIN/spinel-fs-emit" --profile "$PROFILE" --source "$2" -o "$W/$3.o" \
     --emit-llvm "$W/$3.ll" --emit-header "$W/$3.h" --emit-mlir "$W/$3.mlir" --typedump "$READER") \
     > "$W/$3.log" 2>&1
  echo $?
}
locs() { grep -o 'loc("[^"]*":[0-9]*:[0-9]*)' "$W/$1.mlir" | sort -u | tr '\n' ' '; }
mkdir -p "$W/tmp"

echo "locations: 1-2. a required file's method"
ok "spinel-fs-emit compiles the two files" "$(emit "$W/src" main.rb two)" 0
ok "1. g in helper.rb at its own lines, f in main.rb" "$(locs two)" \
   'loc("helper.rb":5:0) loc("helper.rb":6:2) loc("helper.rb":6:6) loc("main.rb":4:0) loc("main.rb":5:2) loc("main.rb":5:9) '
ok "1. the function g is located in helper.rb" \
   "$(grep -c 'func.func private @sp_g(%arg0: i32 loc("helper.rb":5:0))' "$W/two.mlir")" 1
ok "2. no location names the temp directory" "$(grep -c "$W/tmp\|stage2" "$W/two.mlir")" 0

echo "locations: 3. the source named through a directory"
ok "spinel-fs-emit compiles from the parent directory" "$(emit "$W" src/main.rb sub)" 0
ok "the same locations, under src/" "$(locs sub)" \
   'loc("src/helper.rb":5:0) loc("src/helper.rb":6:2) loc("src/helper.rb":6:6) loc("src/main.rb":4:0) loc("src/main.rb":5:2) loc("src/main.rb":5:9) '

echo "locations: 4. control: one file"
mkdir -p "$W/one/spinel" && cp "$W/src/spinel/freestanding.rb" "$W/one/spinel/" || exit 2
sed '2d' "$FIX/main.rb" > "$W/one/main.rb" && sed -n '5,7p' "$FIX/helper.rb" >> "$W/one/main.rb"
ok "spinel-fs-emit compiles it" "$(emit "$W/one" main.rb one)" 0
ok "every location is in main.rb" "$(grep -o 'loc("[^"]*"' "$W/one.mlir" | sort -u | tr '\n' ' ')" 'loc("main.rb" '

echo "locations: 5. a CORE root that requires another file"
mkdir -p "$W/core/src" && cp "$FIX/helper.rb" "$W/core/src/" || exit 2
printf 'require_relative "helper"\n\ndef ent(a)\n  g(a) + 1\nend\n' > "$W/core/src/main.rb"
printf 'core-contract 1\nroot src/main.rb\nentry ent\nresult i64\nparam a scalar i64\n' > "$W/core/k.contract"
"$BIN/spinel-core-kernel" "$W/core/k.contract" --root "$W/core" --typedump "$READER" --clang "$CLANG" \
  -o "$W/core/k.o" --header "$W/core/k.h" --failure-sites "$W/core/sites.tsv" > "$W/core.log" 2>&1
ok "is refused before analysis, as unanalysable" "$?|$(grep -c 'unanalysable-root' "$W/core.log")" "1|1"

echo "locations: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" = 0 ]
