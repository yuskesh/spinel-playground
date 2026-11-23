#!/bin/sh
#
# tests/lowering/split.sh -- a construct that crosses from one file into the
# file that requires it is refused on the freestanding route
# (docs/core/lowering-inputs.md, section 5).
#
#   sh tests/lowering/split.sh DIR
#
#   1. half.rb opens `def g` and the root's `end` closes it: refused, naming
#      half.rb and the parser's own error, with the reason and what to do;
#   2. the root opens `def g` and the required closer.rb holds its `end`:
#      refused, naming closer.rb;
#   3. control: a required file that parses on its own compiles;
#   4. control: a required file that parses on its own but calls a method of
#      the root compiles: only the parse is checked alone.
#
# Needs the native build (SPINEL_CORE_BUILD, default tools/mlir/native/build)
# and the reader (SPINEL_TYPEDUMP, default tools/contract/build/spinel-typedump),
# each held to this tree by its source stamp.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIR=${1:?usage: split.sh DIR}
BIN=${SPINEL_CORE_BUILD:-$ROOT/tools/mlir/native/build}/bin
READER=${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}
PROFILE=$ROOT/tools/freestanding/profiles/cortex-m33-zephyr.yaml
for t in "$BIN/spinel-fs-emit" "$READER"; do
  [ -x "$t" ] || { echo "split: no executable at $t" >&2; exit 2; }
done
. "$ROOT/tools/test/source-stamp.sh"
source_stamp kernel "$BIN/spinel-fs-emit"
source_stamp reader "$READER"
mkdir -p "$DIR" || exit 2
K=$DIR/work
[ -e "$K" ] && { echo "split: $K exists; give a fresh DIR" >&2; exit 2; }
mkdir -p "$K/spinel" && cp "$ROOT/tools/freestanding/spinel/freestanding.rb" "$K/spinel/" || exit 2
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
emit() {
  (cd "$K" && "$BIN/spinel-fs-emit" --profile "$PROFILE" --source "$1.rb" -o "$1.o" --emit-llvm "$1.ll" \
     --emit-header "$1.h" --typedump "$READER") > "$K/$1.err" 2>&1
  echo $?
}
said() { grep -cF "$2" "$K/$1.err"; }
DECL='freestanding_def :f, params: [:i32], returns: :i32'

echo "split: 1. a def opened in a required file, closed in the root"
printf 'def g(x)\n  x * 3\n' > "$K/half.rb"
printf 'require_relative "spinel/freestanding"\nrequire_relative "half"\nend\n%s\ndef f(x)\n  g(x)\nend\n' "$DECL" > "$K/span.rb"
ok "refused" "$(emit span)" 1
ok "naming half.rb and the parser's error" \
   "$(said span 'spinel-mlirgen: unsupported: half.rb does not parse on its own (half.rb:2:8: unexpected end-of-input')" 1
ok "with the reason and what to do" \
   "$(said span 'Ruby parses each required file separately')|$(said span 'Close each construct in the file that opens it.')" "1|1"

echo "split: 2. a def opened in the root, closed in a required file"
printf 'end\n' > "$K/closer.rb"
printf 'require_relative "spinel/freestanding"\ndef g(x)\n  x * 3\nrequire_relative "closer"\n%s\ndef f(x)\n  g(x)\nend\n' "$DECL" > "$K/rev.rb"
ok "refused, naming closer.rb" "$(emit rev)|$(said rev 'unsupported: closer.rb does not parse on its own')" "1|1"

echo "split: 3-4. controls"
printf 'def g(x)\n  x * 3\nend\n' > "$K/whole.rb"
printf 'require_relative "spinel/freestanding"\nrequire_relative "whole"\n%s\ndef f(x)\n  g(x)\nend\n' "$DECL" > "$K/ok.rb"
ok "3. a required file that parses alone compiles" "$(emit ok)" 0
printf 'def g(x)\n  h(x) + 1\nend\n' > "$K/needs.rb"
printf 'require_relative "spinel/freestanding"\nrequire_relative "needs"\ndef h(x)\n  x * 2\nend\n%s\ndef f(x)\n  g(x)\nend\n' "$DECL" > "$K/uses.rb"
ok "4. one that calls a method of the root compiles" "$(emit uses)" 0

echo "split: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" = 0 ]
