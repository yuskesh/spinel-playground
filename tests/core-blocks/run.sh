#!/bin/sh
#
# tests/core-blocks/run.sh -- decision 0041 stage 1: loops with a literal
# block (`times`, `upto`, `downto`, and `each` and `each_with_index` over a
# declared buffer), on both routes that lower them.
#
#   LLVM_PREFIX=/opt/llvm-23.1.1 sh tests/core-blocks/run.sh
#
# 1. The status lane. Each entry of src/ok.rb is compiled by
#    spinel-core-kernel under a contract this script writes, the objects are
#    linked with drive.c, and what the program prints must be expect.txt.
# 2. The status lane's refusals. Each src/refuse/NAME.rb is refused with the
#    category and the words its row below names.
# 3. The freestanding route. fs/k.rb is compiled by spinel-fs-emit for the
#    x86_64 Linux host profile, linked with fs/drive.c, and must print
#    fs/expect.txt.
# 4. The freestanding refusals, each with the words its row names.
# 5. Controls, each with an input it plants: a changed expected line is
#    reported as a difference, and a refusal checked against another row's
#    words fails.
#
# The expected values were written by hand from Ruby's rules; no other
# implementation is run.
#
# Needs the native build (SPINEL_CORE_BUILD, default tools/mlir/native/build)
# and the reader (SPINEL_TYPEDUMP, default tools/contract/build/spinel-typedump),
# each held to this tree by its source stamp, and LLVM_PREFIX (or CLANG) for
# the official LLVM 23.1.1. The x86_64 host profile makes part 3 Linux only;
# elsewhere it is a named skip.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE=$ROOT/tests/core-blocks
BIN=${SPINEL_CORE_BUILD:-$ROOT/tools/mlir/native/build}/bin
KERNEL=$BIN/spinel-core-kernel
EMIT=$BIN/spinel-fs-emit
READER=${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}
PROFILE=$ROOT/tools/freestanding/profiles/x86_64-linux-host.yaml

die() { echo "core-blocks: $*" >&2; exit 2; }
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL (tools/mlir/native/build.sh)"
[ -x "$EMIT" ] || die "no spinel-fs-emit at $EMIT (tools/mlir/native/build.sh)"
[ -x "$READER" ] || die "no reader at $READER (tools/contract/build.sh)"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else die "set LLVM_PREFIX (or CLANG) to the official LLVM 23.1.1; this script refuses to guess"
fi
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"
. "$ROOT/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp kernel "$EMIT"
source_stamp reader "$READER"

T=$(mktemp -d "${TMPDIR:-/tmp}/core-blocks.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0; skip=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }

contract() { # root-relative source, entry, contract path
  printf 'core-contract 1\nroot %s\nentry %s\nresult i64\nparam a scalar i64\nparam b scalar i64\nparam buf buffer i32 inout count n_buf\nparam n_buf scalar u64\n' \
    "$1" "$2" > "$3"
}
kernel() { # contract, object, header; prints the exit status, stderr in $T/err
  "$KERNEL" "$1" --root "$T" --typedump "$READER" -o "$2" --header "$3" \
    --clang "$CC_BIN" > "$T/err" 2>&1
  echo $?
}
# same EXPECTED GOT: `same` when the files are equal, else the first difference
same() { if cmp -s "$1" "$2"; then echo same; else diff "$1" "$2" | sed -n 2p; fi; }

echo "== 1. the status lane =="
mkdir -p "$T/src" "$T/o"
cp "$HERE/src/ok.rb" "$T/src/ok.rb"
entries=$(sed -n 's/^def \(bl_[a-z_]*\)(.*/\1/p' "$HERE/src/ok.rb")
: > "$T/o/bl.h"
objs=""
for e in $entries; do
  contract src/ok.rb "$e" "$T/src/$e.contract"
  ok "$e compiles" "$(kernel "$T/src/$e.contract" "$T/o/$e.o" "$T/o/$e.h")" 0
  [ -f "$T/o/$e.h" ] && echo "#include \"$e.h\"" >> "$T/o/bl.h"
  objs="$objs $T/o/$e.o"
done
if "$CC_BIN" -I"$T/o" "$HERE/drive.c" $objs -o "$T/drive" > "$T/link.err" 2>&1; then
  "$T/drive" > "$T/out" 2>&1
  ok "the calls give expect.txt" "$(same "$HERE/expect.txt" "$T/out")" same
else
  echo "  FAIL the entries do not link with drive.c"; sed 's/^/      /' "$T/link.err" | head -4
  fail=$((fail + 1))
fi

echo "== 2. the status lane's refusals =="
# refused NAME CATEGORY WORDS: the exit status, then whether
# `not-eligible: CATEGORY: ...WORDS` is there
refused() {
  cp "$HERE/src/refuse/$1.rb" "$T/src/r_$1.rb"
  contract "src/r_$1.rb" probe "$T/src/r_$1.contract"
  rc=$(kernel "$T/src/r_$1.contract" /dev/null /dev/null)
  printf '%s|%s' "$([ "$rc" = 1 ] && echo refused || echo "exit $rc")" \
    "$(grep -F "not-eligible: $2: " "$T/err" | grep -cF "$3")"
}
while IFS='|' read -r name category words; do
  case $name in ''|\#*) continue ;; esac
  ok "$name: $category" "$(refused "$name" "$category" "$words")" "refused|1"
done <<'EOF'
value|loop-value|the value of a `times` loop is used
value_assign|loop-value|the value of a `times` loop is used
map|unsupported-block|`map` with a block: only `times`, `upto`, `downto`, `each` and `each_with_index`
block_arg|unsupported-block|`times(&:name)`: a block argument is not admitted
numbered|unsupported-block|`times` with a numbered or `it` parameter
it_param|unsupported-block|`times` with a numbered or `it` parameter
too_many|unsupported-block|`times` yields 1 value(s), and its block names 2 parameters
upto_args|unsupported-block|`upto` takes 1 argument(s) here, and is given 2
shadow|unsupported-block|the block's `i` has the name of a local of an enclosing scope
each_scalar|unsupported-block|`each` is a loop only on a buffer this method holds
break_value|loop-control-value|`break` carries a value
fresh|type-evidence|local t is conflicting
yield_call|unsupported-node|YieldNode
EOF

echo "== 3. the freestanding route =="
mkdir -p "$T/fs/spinel"
cp "$ROOT/tools/freestanding/spinel/freestanding.rb" "$T/fs/spinel/"
# emit FILE: compiles a copy as $T/fs/k.rb; prints the exit status, stderr in $T/fs/err
emit() {
  cp "$1" "$T/fs/k.rb" || return 2
  (cd "$T/fs" && "$EMIT" k.rb --freestanding --profile "$PROFILE" --typedump "$READER" \
     -o k.o --emit-header k.h) > "$T/fs/err" 2>&1
  echo $?
}
if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ]; then
  ok "fs/k.rb compiles" "$(emit "$HERE/fs/k.rb")" 0
  if "$CC_BIN" -I"$T/fs" "$HERE/fs/drive.c" "$T/fs/k.o" -o "$T/fs/drive" > "$T/fs/link.err" 2>&1; then
    "$T/fs/drive" > "$T/fs/out" 2>&1
    ok "the calls give fs/expect.txt" "$(same "$HERE/fs/expect.txt" "$T/fs/out")" same
  else
    echo "  FAIL fs/k.rb does not link with fs/drive.c"; sed 's/^/      /' "$T/fs/link.err" | head -4
    fail=$((fail + 1))
  fi
else
  echo "  SKIP the freestanding values: the x86_64 Linux host profile does not run on $(uname -s) $(uname -m)"
  skip=$((skip + 1))
fi

echo "== 4. the freestanding refusals =="
# fs_refused NAME WORDS: the exit status, then whether the words are on the
# `spinel-mlirgen: unsupported:` line
fs_refused() {
  rc=$(emit "$HERE/fs/refuse/$1.rb")
  printf '%s|%s' "$([ "$rc" != 0 ] && echo refused || echo "exit $rc")" \
    "$(grep -F "spinel-mlirgen: unsupported: " "$T/fs/err" | grep -cF "$2")"
}
while IFS='|' read -r name words; do
  case $name in ''|\#*) continue ;; esac
  ok "fs $name" "$(fs_refused "$name" "$words")" "refused|1"
done <<'EOF'
value|the value of a `times` loop is used
map|`map` allocates the result Array.
block_arg|`times(&:name)`: a block argument is not admitted
numbered|`times` with a numbered or `it` parameter
too_many|`times` yields 1 value(s), and its block names 2 parameters
upto_args|`upto` takes 1 argument(s) here, and is given 2
shadow|the block's `i` has the name of a local of an enclosing scope
each_scalar|`each` is a loop only on a declared buffer parameter
fresh|`t` is a local of a `times` block and is read before it is assigned on some path
yield_call|YieldNode is not in the freestanding subset
EOF

echo "== 5. controls =="
# a. One expected line changed is reported, so section 1's comparison can fail.
if [ -f "$T/out" ]; then
  sed 's/^times 4 0 0 6$/times 4 0 0 7/' "$HERE/expect.txt" > "$T/planted.txt"
  ok "a changed expected line is a difference" \
    "$(same "$T/planted.txt" "$T/out")" "< times 4 0 0 7"
else
  echo "  FAIL control a needs section 1's output"; fail=$((fail + 1))
fi
# b. A refusal checked against another row's words does not pass.
ok "map is not refused as a used loop value" \
  "$(refused map loop-value 'the value of a `times` loop is used')" "refused|0"

echo "core-blocks: $pass passed, $fail failed, $skip skipped"
[ "$fail" = 0 ]
