#!/bin/sh
#
# tests/lowering/duplicate.sh -- a method defined twice at the top level is
# refused on the freestanding route with the reason in the line
# (docs/core/lowering-inputs.md, section 4).
#
#   sh tests/lowering/duplicate.sh DIR
#
#   1. two top-level `def g` and a declared f that calls g: refused with
#      `spinel-mlirgen: unsupported: 'g' (duplicate-method: ...)`: the frozen
#      generator's spelling first, as tests/freestanding/e081 pins it, and the
#      reason after the name;
#   2. control: the freestanding route still drops the importer's category
#      from its other refusals (`arity-mismatch` for a call with too few
#      arguments), as the frozen generator's spelling does;
#   3. control: one `def g` compiles.
#
# Needs the native build (SPINEL_CORE_BUILD, default tools/mlir/native/build)
# and the reader (SPINEL_TYPEDUMP, default tools/contract/build/spinel-typedump),
# each held to this tree by its source stamp.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIR=${1:?usage: duplicate.sh DIR}
BIN=${SPINEL_CORE_BUILD:-$ROOT/tools/mlir/native/build}/bin
READER=${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}
PROFILE=$ROOT/tools/freestanding/profiles/cortex-m33-zephyr.yaml
for t in "$BIN/spinel-fs-emit" "$READER"; do
  [ -x "$t" ] || { echo "duplicate: no executable at $t" >&2; exit 2; }
done
. "$ROOT/tools/test/source-stamp.sh"
source_stamp kernel "$BIN/spinel-fs-emit"
source_stamp reader "$READER"
mkdir -p "$DIR" || exit 2
K=$DIR/work
[ -e "$K" ] && { echo "duplicate: $K exists; give a fresh DIR" >&2; exit 2; }
mkdir -p "$K/spinel" && cp "$ROOT/tools/freestanding/spinel/freestanding.rb" "$K/spinel/" || exit 2
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
emit() {
  (cd "$K" && "$BIN/spinel-fs-emit" --profile "$PROFILE" --source "$1.rb" -o "$1.o" --emit-llvm "$1.ll" \
     --emit-header "$1.h" --typedump "$READER") > "$K/$1.err" 2>&1
  echo $?
}
said() { grep -cxF "$2" "$K/$1.err"; }
# kernel NAME BODY-OF-G...: K/NAME.rb with each argument as a top-level def g
kernel() {
  n=$1; shift
  { echo 'require_relative "spinel/freestanding"'
    for b in "$@"; do printf 'def g(x)\n  %s\nend\n' "$b"; done
    printf 'freestanding_def :f, params: [:i32], returns: :i32\ndef f(x)\n  g(x)\nend\n'; } > "$K/$n.rb"
}

echo "duplicate: 1. g defined twice"
kernel twice 'x + 1' 'x + 2'
ok "refused, with the reason after the name" \
   "$(emit twice)|$(said twice "spinel-mlirgen: unsupported: 'g' (duplicate-method: defined more than once at the top level)")" "1|1"

echo "duplicate: 2-3. controls"
printf 'require_relative "spinel/freestanding"\ndef g(a, b)\n  a + b\nend\nfreestanding_def :f, params: [:i32], returns: :i32\ndef f(x)\n  g(x)\nend\n' > "$K/arity.rb"
ok "2. another importer refusal keeps the generator's spelling, without its category" \
   "$(emit arity)|$(said arity "spinel-mlirgen: unsupported: call to 'g' with 1 arguments, expected 2")|$(grep -c 'arity-mismatch' "$K/arity.err")" "1|1|0"
kernel once 'x + 1'
ok "3. g defined once compiles" "$(emit once)" 0

echo "duplicate: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" = 0 ]
