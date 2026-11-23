#!/bin/sh
#
# tests/lowering/reopened.sh -- a builtin class changed at the top level is
# refused on the freestanding route, as on the CORE route
# (docs/core/lowering-inputs.md, defect (ii)).
#
#   sh tests/lowering/reopened.sh DIR
#
# A declared f(x) computes `x + 1`, which the lowering turns into the
# builtin checked add. Beside it, at the top level:
#
#   1. `class Integer` with its own `+`: refused by spinel-fs-emit, naming the
#      file, the line and the form, with the reason and what to do instead;
#   2. `Integer.prepend(M)`: refused, naming `Integer.prepend`;
#   3. `class << Float`: refused, naming `class << Float`;
#   4. the reopening in a file the kernel requires: refused, naming that file
#      and its line;
#   5. control: the kernel without any of them compiles, and `x + 1` is the
#      builtin checked add;
#   6. control: a top-level class of another name compiles, and a prepend on
#      one is still refused, but not named as a builtin change;
#   7. control: the CORE kernel refuses the reopening of 1 (binding-environment).
#
# Needs the native build (SPINEL_CORE_BUILD, default tools/mlir/native/build)
# and the reader (SPINEL_TYPEDUMP, default tools/contract/build/spinel-typedump),
# each held to this tree by its source stamp; LLVM_PREFIX for the kernel's clang.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIR=${1:?usage: reopened.sh DIR}
BIN=${SPINEL_CORE_BUILD:-$ROOT/tools/mlir/native/build}/bin
READER=${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}
CLANG=${CLANG:-${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/clang}
PROFILE=$ROOT/tools/freestanding/profiles/cortex-m33-zephyr.yaml
for t in "$BIN/spinel-fs-emit" "$BIN/spinel-core-kernel" "$READER" "$CLANG"; do
  [ -x "$t" ] || { echo "reopened: no executable at $t" >&2; exit 2; }
done
. "$ROOT/tools/test/source-stamp.sh"
source_stamp kernel "$BIN/spinel-fs-emit"
source_stamp reader "$READER"
mkdir -p "$DIR" || exit 2
K=$DIR/work
[ -e "$K" ] && { echo "reopened: $K exists; give a fresh DIR" >&2; exit 2; }
mkdir -p "$K/spinel" && cp "$ROOT/tools/freestanding/spinel/freestanding.rb" "$K/spinel/" || exit 2
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
# kernel NAME TOPLEVEL: K/NAME.rb with TOPLEVEL above the declared f
kernel() {
  { printf 'require_relative "spinel/freestanding"\n%s\n' "$2"
    printf 'freestanding_def :f, params: [:i32], returns: :i32\ndef f(x)\n  x + 1\nend\n'; } > "$K/$1.rb"
}
# emit NAME: exit status; stderr in K/NAME.err, MLIR in K/NAME.mlir
emit() {
  (cd "$K" && "$BIN/spinel-fs-emit" --profile "$PROFILE" --source "$1.rb" -o "$1.o" --emit-llvm "$1.ll" \
     --emit-header "$1.h" --emit-mlir "$1.mlir" --typedump "$READER") > "$K/$1.err" 2>&1
  echo $?
}
said() { grep -cF "$2" "$K/$1.err"; }
REASON="A freestanding method's operators on an Integer or a Float lower to the builtin operation"

echo "reopened: 1. class Integer"
kernel reopen "$(printf 'class Integer\n  def +(o)\n    42\n  end\nend')"
ok "refused" "$(emit reopen)" 1
ok "naming the file, the line and the form" "$(said reopen 'spinel-mlirgen: unsupported: reopen.rb:2: `class Integer` changes the builtin class Integer at the top level.')" 1
ok "with the reason" "$(said reopen "$REASON")" 1
ok "and what to do instead" "$(said reopen 'Remove it, or write the operation as a top-level method the declared method calls.')" 1

echo "reopened: 2. Integer.prepend"
kernel prepend "$(printf 'module M\n  def +(o)\n    42\n  end\nend\nInteger.prepend(M)')"
ok "refused, naming Integer.prepend" "$(emit prepend)|$(said prepend 'prepend.rb:7: `Integer.prepend` changes the builtin class Integer')" "1|1"

echo "reopened: 3. class << Float"
kernel single "$(printf 'class << Float\n  def zero\n    0.0\n  end\nend')"
ok "refused, naming class << Float" "$(emit single)|$(said single 'single.rb:2: `class << Float` changes the builtin class Float')" "1|1"

echo "reopened: 4. in a required file"
printf '# ext.rb\nclass Integer\n  def +(o)\n    42\n  end\nend\n' > "$K/ext.rb"
kernel required 'require_relative "ext"'
ok "refused, naming the required file and its line" "$(emit required)|$(said required 'ext.rb:2: `class Integer`')" "1|1"

echo "reopened: 5-6. controls"
kernel plain ''
ok "5. without them f compiles" "$(emit plain)" 0
ok "5. and x + 1 is the builtin checked add" "$(grep -c 'spinel.checked_add' "$K/plain.mlir")" 1
kernel point "$(printf 'class Point\n  def +(o)\n    42\n  end\nend')"
ok "6. a top-level class of another name compiles" "$(emit point)" 0
# Spinel's analysis writes a prepend out as appended nodes the reader refuses;
# case 2's message comes from a second, diagnostic-only read. A prepend on a
# class of another name must still be refused by the first read, unnamed.
kernel userpre "$(printf 'class Point\nend\nmodule M\n  def g\n    1\n  end\nend\nPoint.prepend(M)')"
ok "6b. a prepend on a class of another name stays refused, not as a builtin" \
   "$(emit userpre)|$(said userpre 'changes the builtin class')|$(said userpre 'contract-rejected')" "1|0|1"

echo "reopened: 7. the CORE route"
mkdir -p "$K/core/src"
printf 'class Integer\n  def +(o)\n    42\n  end\nend\n\ndef f(x)\n  x + 1\nend\n' > "$K/core/src/reopen.rb"
printf 'core-contract 1\nroot src/reopen.rb\nentry f\nresult i64\nparam x scalar i64\n' > "$K/core/k.contract"
"$BIN/spinel-core-kernel" "$K/core/k.contract" --root "$K/core" --typedump "$READER" --clang "$CLANG" \
  -o "$K/core/k.o" --header "$K/core/k.h" > "$K/core.err" 2>&1
ok "the CORE kernel refuses the same reopening" "$?|$(grep -c 'not-eligible: binding-environment' "$K/core.err")" "1|1"

echo "reopened: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" = 0 ]
