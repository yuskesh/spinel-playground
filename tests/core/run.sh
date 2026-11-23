#!/bin/sh
# Acceptance checks for the native core slice.
#
# What this establishes, and what it does not: it drives one declaration
# through the whole path -- freestanding_def, the contract reader, the typed
# subset check, the MLIR importer and lowering, a standalone object with its
# header, the undefined-symbol gate -- and then calls the result from an
# ordinary C host. It says nothing about the hosted Spinel side: no full-tier
# program calls a core function here.
#
# The i32 boundary narrowing check and the internal i64 arithmetic overflow
# check are deliberately separate cases on separate kernels. They are different
# mechanisms with different trap codes, and passing one does not establish the
# other.
#
# usage: tests/core/run.sh
#   SPINEL_CORE_BUILD  build directory holding bin/spinel-fs-emit (required)
#   SPINEL_TYPEDUMP    contract reader (default: tools/contract/build/spinel-typedump)
#   CLANG              C compiler for the host programs. Defaults to the
#                      clang of the LLVM this build directory was configured
#                      against, NOT to whatever `clang` is on PATH -- see below.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
fixtures="$here/fixtures"

BUILD="${SPINEL_CORE_BUILD:-}"
if [ -z "$BUILD" ]; then
  echo "run.sh: set SPINEL_CORE_BUILD to the directory holding bin/spinel-fs-emit" >&2
  exit 2
fi
# The helpers below run the tools from a temporary directory, so every path
# handed to them has to be absolute. A relative SPINEL_CORE_BUILD is the
# documented form and used to survive the guard here and then fail at the first
# invocation with "not found".
[ -d "$BUILD" ] || { echo "run.sh: no such directory: $BUILD" >&2; exit 2; }
BUILD=$(CDPATH= cd -- "$BUILD" && pwd)
EMIT="$BUILD/bin/spinel-fs-emit"
CHECK="$BUILD/bin/spinel-fs-check"
TYPEDUMP="${SPINEL_TYPEDUMP:-$root/tools/contract/build/spinel-typedump}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$EMIT"
source_stamp kernel "$CHECK"
source_stamp reader "$TYPEDUMP"
case "$TYPEDUMP" in
  /*) ;;
  *) TYPEDUMP=$(CDPATH= cd -- "$(dirname -- "$TYPEDUMP")" 2>/dev/null && pwd)/$(basename -- "$TYPEDUMP") ;;
esac
# spinel-fs-emit used to hand its LLVM IR to clang to assemble, and a clang
# from a DIFFERENT LLVM could not read it: LLVM 19 rejects the attribute
# `nocreateundeforpoison` that LLVM 23 emits, reporting it as "unterminated
# attribute group" in the .ll. Now spinel-fs-codegen, built against the same
# LLVM, writes the object, and CLANG only compiles the C below.
#
# The default is still the clang this build directory was CONFIGURED with, read
# back from its CMake cache, rather than bare `clang` from PATH, so the C here
# and the objects come from one LLVM. An explicit CLANG= is honoured and checked
# against the same value: a mismatch is refused up front with the version of
# each.
CORE_CLANG=""
if [ -f "$BUILD/CMakeCache.txt" ]; then
  CORE_CLANG=$(sed -n 's|^CMAKE_C_COMPILER:[A-Z]*=\(.*\)$|\1|p' "$BUILD/CMakeCache.txt" | head -1)
  [ -x "$CORE_CLANG" ] || CORE_CLANG=""
fi
if [ -z "${CLANG:-}" ]; then
  if [ -n "$CORE_CLANG" ]; then CLANG="$CORE_CLANG"
  else
    echo "run.sh: $BUILD has no CMakeCache.txt naming its C compiler, and CLANG is unset." >&2
    echo "run.sh: set CLANG to the clang of the LLVM spinel-fs-emit was built against." >&2
    exit 2
  fi
fi
command -v "$CLANG" >/dev/null 2>&1 || { echo "run.sh: no C compiler: $CLANG" >&2; exit 2; }
if [ -n "$CORE_CLANG" ]; then
  _want=$("$CORE_CLANG" --version 2>/dev/null | sed -n 's/.*[Cc]lang version \([0-9.]*\).*/\1/p' | head -1)
  _have=$("$CLANG"      --version 2>/dev/null | sed -n 's/.*[Cc]lang version \([0-9.]*\).*/\1/p' | head -1)
  if [ -n "$_want" ] && [ -n "$_have" ] && [ "$_want" != "$_have" ]; then
    echo "run.sh: CLANG is clang $_have ($CLANG), but $BUILD was built against clang $_want ($CORE_CLANG)." >&2
    echo "run.sh: spinel-fs-emit writes its objects with that LLVM." >&2
    echo "run.sh: unset CLANG to use the matching one, or point it at clang $_want." >&2
    exit 2
  fi
fi
PROFILE="$root/tools/freestanding/profiles/x86_64-linux-host.yaml"

for f in "$EMIT" "$CHECK" "$TYPEDUMP"; do
  [ -x "$f" ] || { echo "run.sh: missing or not executable: $f" >&2; exit 2; }
done
work=$(mktemp -d "${TMPDIR:-/tmp}/spinel-core-test.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM
mkdir -p "$work/spinel"
cp "$root/tools/freestanding/spinel/freestanding.rb" "$work/spinel/"

pass=0
fail=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; [ $# -lt 2 ] || printf '     %s\n' "$2"; }

# emit <fixture> <stem> -> object + header in $work, log in $work/<stem>.log
emit() {
  cp "$fixtures/$1" "$work/$2.rb"
  ( cd "$work" && "$EMIT" --profile "$PROFILE" --source "$2.rb" \
      -o "$2.o" --emit-llvm "$2.ll" --emit-header "$2.h" --emit-mlir "$2.mlir" \
      --typedump "$TYPEDUMP" ) > "$work/$2.log" 2>&1
}

# ---------------------------------------------------------------- emission --
if emit add_i32.rb k32; then ok "i32 kernel emits"; else bad "i32 kernel emits" "$(tail -2 "$work/k32.log")"; fi
[ -s "$work/k32.o" ] && ok "object is produced and non-empty" || bad "object is produced and non-empty"
[ -s "$work/k32.h" ] && ok "header is produced and non-empty" || bad "header is produced and non-empty"
grep -q 'int32_t spinel_add(int32_t, int32_t);' "$work/k32.h" \
  && ok "header declares the boundary prototype" \
  || bad "header declares the boundary prototype" "$(cat "$work/k32.h")"
grep -q 'void spinel_trap(' "$work/k32.h" \
  && ok "header declares the trap hook" || bad "header declares the trap hook"

# ------------------------------------------------- no runtime or GC linkage --
# Two independent readings of the same fact: the gate's verdict, and the raw
# symbol table. The gate alone would not show a symbol it forgot to classify.
if "$CHECK" --undef --profile "$PROFILE" "$work/k32.o" > "$work/gate.out" 2>"$work/gate.err"; then
  ok "undef gate accepts the object"
else
  bad "undef gate accepts the object" "$(cat "$work/gate.err")"
fi
grep -q '^ALLOW.*spinel_trap' "$work/gate.out" \
  && ok "gate allows the declared trap extern" || bad "gate allows the declared trap extern" "$(cat "$work/gate.out")"
# Absence of DENY only means something once the gate is known to have produced
# verdicts. On an empty file the grep is false and the check would pass while
# saying nothing.
if ! grep -q '^ALLOW' "$work/gate.out"; then
  bad "gate reports no denial" "the gate produced no verdict at all"
elif grep -q '^DENY' "$work/gate.out"; then
  bad "gate reports no denial" "$(cat "$work/gate.out")"
else
  ok "gate reports no denial"
fi

undef=$(${NM:-nm} -u "$work/k32.o" 2>/dev/null | sed 's/^ *U *//' | sed '/^$/d' | sort | tr '\n' ' ')
[ "$undef" = "spinel_trap " ] \
  && ok "the only undefined symbol is the trap hook" \
  || bad "the only undefined symbol is the trap hook" "saw: $undef"

# ------------------------------------- the gate refuses what is not allowed --
# Without this the gate checks above only establish that it says yes. A gate
# that said yes to everything would pass them.
if "$CLANG" -O2 -c "$fixtures/deny_extern.c" -o "$work/deny.o" >"$work/deny.cc.log" 2>&1; then
  ok "control object compiles"
else
  bad "control object compiles" "$(tail -2 "$work/deny.cc.log")"
fi
if "$CHECK" --undef --profile "$PROFILE" "$work/deny.o" > "$work/deny.out" 2>"$work/deny.err"; then
  bad "gate refuses an object with disallowed externs" "the gate accepted it: $(cat "$work/deny.out")"
else
  ok "gate refuses an object with disallowed externs"
fi
grep -q '^DENY.*malloc' "$work/deny.out" \
  && ok "gate denies the allocator by name" || bad "gate denies the allocator by name" "$(cat "$work/deny.out")"
grep -q '^DENY.*platform_thing' "$work/deny.out" \
  && ok "gate denies the undeclared extern by name" || bad "gate denies the undeclared extern by name" "$(cat "$work/deny.out")"
grep -qi 'allocation' "$work/deny.out" \
  && ok "the allocator denial states a reason" || bad "the allocator denial states a reason" "$(cat "$work/deny.out")"
grep -q 'not allowed by this profile' "$work/deny.err" \
  && ok "the gate summarises the refusal" || bad "the gate summarises the refusal" "$(cat "$work/deny.err")"

# --------------------------------------------------------- values on a host --
cp "$fixtures/harness_i32.c" "$work/host32.c"
cp "$work/k32.h" "$work/kernel.h" 2>/dev/null || : > "$work/kernel.h"
if ( cd "$work" && "$CLANG" -O2 -I. host32.c k32.o -o host32 ) >"$work/link32.log" 2>&1; then
  ok "core object links into a C host"
else
  bad "core object links into a C host" "$(tail -3 "$work/link32.log")"
fi

expect_value() { # name argA argB expected
  if got=$("$work/host32" "$2" "$3" 2>&1); then :; else got="(exit $?) $got"; fi
  [ "$got" = "$4" ] && ok "$1" || bad "$1" "expected '$4', got '$got'"
}
expect_value "host call returns 5 for add(2,3)"            2 3 5
expect_value "host call returns -3 for add(-7,4)"         -7 4 -3
expect_value "upper boundary value passes through"  2147483647 0 2147483647
expect_value "lower boundary value passes through" -2147483648 0 -2147483648
# The non-trap control for the narrowing check: one below the edge must NOT trap.
expect_value "one below the upper edge does not trap" 2147483646 1 2147483647

# ------------------------------- i32 boundary narrowing trap (return range) --
# Mechanism: the i64 body computed a value, and the declared i32 return cannot
# hold it. This is NOT the internal arithmetic check; see the i64 case below.
# A trap exits 42 on purpose, so the command substitution has to be allowed to
# fail without taking `set -e` with it.
narrow_trap() { # name argA argB
  if out=$("$work/host32" "$2" "$3" 2>&1); then rc=0; else rc=$?; fi
  if [ "$rc" -eq 42 ] && echo "$out" | grep -q 'code=3' \
     && echo "$out" | grep -q 'does not fit i32'; then ok "$1"
  else bad "$1" "rc=$rc out=$out"; fi
}
narrow_trap "return above i32 range traps with code 3"  2147483647 1
narrow_trap "return below i32 range traps with code 3" -2147483648 -1

# ------------------------------- internal i64 arithmetic overflow (separate) --
# Different kernel, different mechanism, different code. A declaration whose
# boundary is i64 has no narrowing step at all, so a trap here can only come
# from the checked arithmetic in the body.
if emit add_i64.rb k64; then ok "i64 kernel emits"; else bad "i64 kernel emits" "$(tail -2 "$work/k64.log")"; fi
grep -q 'spinel.checked_add .* policy trap' "$work/k64.mlir" \
  && ok "i64 body carries a checked add under the trap policy" \
  || bad "i64 body carries a checked add under the trap policy"
grep -q 'trunci' "$work/k64.mlir" \
  && bad "i64 boundary has no narrowing step" "trunci present" \
  || ok "i64 boundary has no narrowing step"
cp "$fixtures/harness_i64.c" "$work/host64.c"
cp "$work/k64.h" "$work/kernel.h" 2>/dev/null || : > "$work/kernel.h"
if ( cd "$work" && "$CLANG" -O2 -I. host64.c k64.o -o host64 ) >"$work/link64.log" 2>&1; then
  ok "i64 core object links into a C host"
else
  bad "i64 core object links into a C host" "$(tail -3 "$work/link64.log")"
fi
if got=$("$work/host64" 9223372036854775806 1 2>&1); then :; else got="(exit $?) $got"; fi
[ "$got" = "9223372036854775807" ] \
  && ok "i64 arithmetic below the edge does not trap" \
  || bad "i64 arithmetic below the edge does not trap" "got '$got'"
if out=$("$work/host64" 9223372036854775807 1 2>&1); then rc=0; else rc=$?; fi
if [ "$rc" -eq 42 ] && echo "$out" | grep -q 'code=1' \
   && echo "$out" | grep -q 'integer overflow in +'; then
  ok "i64 arithmetic overflow traps with code 1"
else
  bad "i64 arithmetic overflow traps with code 1" "rc=$rc out=$out"
fi

# ------------------------------------------------- refusals, with a control --
refuse() { # name fixture stem expected-substring
  if emit "$2" "$3"; then
    bad "$1" "emission succeeded but should have been refused"
  else
    if grep -q "$4" "$work/$3.log"; then ok "$1"
    else bad "$1" "refused, but not for the stated reason: $(grep -v pre-T5 "$work/$3.log" | head -1)"; fi
  fi
}
refuse "array indexing is refused"   reject_array.rb  bad_a "indexes a heap object"
refuse "string literal is refused"   reject_string.rb bad_s "not in the freestanding subset"
refuse "undeclared call is refused"  reject_puts.rb   bad_p "is not declared by the profile"
# The control that keeps the three above from passing vacuously: a kernel that
# breaks none of those rules must still emit.
if emit accept_min.rb good; then ok "a conforming kernel still emits (refusal control)"
else bad "a conforming kernel still emits (refusal control)" "$(tail -2 "$work/good.log")"; fi

printf '\n%s\n' "core acceptance: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
