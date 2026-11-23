#!/bin/sh
#
# tests/doom-core/borrowed-calls.sh — decision 0008 task 3.
#
# A contract declares the ENTRY's buffers. A helper has no contract, so what
# it may do with a buffer it is handed is DERIVED, and this measures that
# derivation three ways:
#
#   * what the closure computes, by running it -- a positive fixture is
#     compiled, linked against a C harness and executed, and its status,
#     result and the bytes it did or did not touch are compared;
#   * what it refuses, by name -- a refusal fixture must produce ITS OWN
#     category, not merely a nonzero exit, because everything here exits
#     nonzero;
#   * that the bound is the descriptor's and not the body's, by moving the
#     Ruby local the count was read from and showing the bound does not move.
#
#   LLVM_PREFIX=/opt/llvm-23.1.1 sh tests/doom-core/borrowed-calls.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIX="$ROOT/tests/doom-core/fixtures/borrowed-calls"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
# The kernel is told which contract reader to use. Left to itself it walks up
# from its own directory looking for one, which makes what it reads depend on
# where the binary happens to sit.
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
. "$ROOT/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"

die() { echo "borrowed-calls: $*" >&2; exit 1; }
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL (build tools/mlir/native first)"
[ -d "$FIX" ] || die "no fixtures at $FIX"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else die "set LLVM_PREFIX (or CLANG) to the official LLVM 23.1.1; this script refuses to guess"
fi
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"
# The symbol reader is the toolchain's, for the same reason the compiler is: a
# host nm reads the objects with its own conventions. AGENTS.md requires NM to
# be exported for these suites; fall back to the prefix rather than to $PATH.
if [ -n "${NM:-}" ]; then NM_BIN=$NM
elif [ -n "${LLVM_PREFIX:-}" ]; then NM_BIN=$LLVM_PREFIX/bin/llvm-nm
else die "set NM (or LLVM_PREFIX) to the official LLVM 23.1.1's llvm-nm"
fi
[ -x "$NM_BIN" ] || die "no symbol reader at $NM_BIN"

W=$(mktemp -d "${TMPDIR:-/tmp}/doom-core-borrow.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
want() { if grep -qE "$3" "$2"; then echo "  pass $1"; pass=$((pass + 1));
         else echo "  FAIL $1"; sed 's/^/        /' "$2" | head -6; fail=$((fail + 1)); fi; }
reject() { if grep -qE "$3" "$2"; then echo "  FAIL $1 (the wrong answer is present)"; fail=$((fail + 1));
           else echo "  pass $1"; pass=$((pass + 1)); fi; }

build() { # stem dir -> $W/<stem>.o, $W/<stem>.h, $W/<stem>.err
  "$KERNEL" "$FIX/$2/$1.contract" --root "$FIX" --typedump "$READER" -o "$W/$1.o" --header "$W/$1.h" \
    --clang "$CC_BIN" > "$W/$1.err" 2>&1 && echo 0 > "$W/$1.rc" || echo $? > "$W/$1.rc"
}

echo "== a borrowed buffer crosses a call =="
for stem in dc_pick dc_nested dc_two dc_twice_ro dc_store dc_i64 dc_bool dc_order; do
  build "$stem" src
  ok "$stem compiles" "$(cat "$W/$stem.rc")" 0
done

# The harness. Every positive fixture is linked into one program so a symbol
# clash between two kernels would show up here rather than later.
cat > "$W/h.c" <<'CEOF'
#include <stdio.h>
#include <stdint.h>
#include "dc_pick.h"
#include "dc_nested.h"
#include "dc_two.h"
#include "dc_twice_ro.h"
#include "dc_store.h"
#include "dc_i64.h"
#include "dc_bool.h"
#include "dc_order.h"
int main(void) {
  int64_t r; int32_t s;
  int32_t d[2] = {11, 99};

  r = 123; s = spinel_core_dc_pick(d, 1, 0, &r);
  printf("pick-in %d %lld %d\n", s, (long long)r, d[1]);
  r = 123; s = spinel_core_dc_pick(d, 1, 1, &r);
  printf("pick-out %d %lld %d\n", s, (long long)r, d[1]);
  r = 123; s = spinel_core_dc_pick(d, 1, -1, &r);
  printf("pick-neg %d %lld %d\n", s, (long long)r, d[1]);
  /* The count the CALLER was given, not the local it reassigned: the body
     does `n_data = n_data + 100` before the call. With a real count of 2 the
     helper may read index 1; with 1 it may not, and 101 never enters it. */
  r = 123; s = spinel_core_dc_pick(d, 2, 1, &r);
  printf("pick-count2 %d %lld\n", s, (long long)r);

  r = 123; s = spinel_core_dc_nested(d, 1, 0, &r);
  printf("nested-in %d %lld\n", s, (long long)r);
  r = 123; s = spinel_core_dc_nested(d, 1, 1, &r);
  printf("nested-out %d %lld %d\n", s, (long long)r, d[1]);

  int32_t a[3] = {1, 2, 3};
  int32_t b[1] = {40};
  r = 123; s = spinel_core_dc_two(a, 3, b, 1, 0, &r);
  printf("two-in %d %lld\n", s, (long long)r);
  /* index 2 is inside `a` and outside `b`: each call carries its own count */
  r = 123; s = spinel_core_dc_two(a, 3, b, 1, 2, &r);
  printf("two-mixed %d %lld\n", s, (long long)r);

  r = 123; s = spinel_core_dc_twice_ro(d, 1, 0, &r);
  printf("twice-ro %d %lld\n", s, (long long)r);

  int32_t m[2] = {5, 99};
  r = 123; s = spinel_core_dc_store(m, 1, 0, 7, &r);
  printf("store-ok %d %d %d\n", s, m[0], m[1]);
  r = 123; s = spinel_core_dc_store(m, 1, 0, 4294967296LL, &r);
  printf("store-narrow %d %d %d\n", s, m[0], m[1]);
  r = 123; s = spinel_core_dc_store(m, 1, 1, 8, &r);
  printf("store-bounds %d %d %d\n", s, m[0], m[1]);

  int64_t w[2] = {INT64_MIN, 99};
  r = 123; s = spinel_core_dc_i64(w, 1, 0, &r);
  printf("i64-min %d %lld\n", s, (long long)r);
  r = 123; s = spinel_core_dc_i64(w, 0x8000000000000001ULL, -1, &r);
  printf("i64-huge %d %lld\n", s, (long long)r);

  r = 123; s = spinel_core_dc_bool(d, 1, 0, &r);
  printf("bool-in %d %lld\n", s, (long long)r);
  r = 123; s = spinel_core_dc_bool(d, 1, 5, &r);
  printf("bool-out %d %lld\n", s, (long long)r);

  /* `buf[0] += dc_rhs(buf)` where dc_rhs stores 6 and returns 5. Ruby reads
     the element BEFORE the call, so the answer is 1 + 5. Emitting the load
     after the call gave 6 + 5 = 11 with an OK status. */
  { int32_t o[1] = {1};
    r = 123; s = spinel_core_dc_order(o, 1, &r);
    printf("order %d %lld %d\n", s, (long long)r, (int)o[0]); }
  return 0;
}
CEOF
objs=""
for stem in dc_pick dc_nested dc_two dc_twice_ro dc_store dc_i64 dc_bool dc_order; do objs="$objs $W/$stem.o"; done
if "$CC_BIN" -I"$W" "$W/h.c" $objs -o "$W/h" > "$W/link.err" 2>&1; then
  echo "  pass the eight kernels link into one program"; pass=$((pass + 1))
else
  echo "  FAIL they do not link"; sed 's/^/        /' "$W/link.err" | head -6; fail=$((fail + 1))
fi
"$W/h" > "$W/out" 2>&1 || true
say() { grep "^$1 " "$W/out" | head -1 | cut -d' ' -f2-; }

echo "== what it computes, and what it leaves alone =="
ok "index 0 is OK and reads the element"        "$(say pick-in)"      "0 11 99"
ok "index 1 is BOUNDS, result and guard intact" "$(say pick-out)"     "3 123 99"
ok "a negative index is BOUNDS too"             "$(say pick-neg)"     "3 123 99"
ok "the bound is the descriptor's, not the body's local" \
                                                "$(say pick-count2)"  "0 99"
ok "the borrow travels two calls deep"          "$(say nested-in)"    "0 11"
ok "and the bound travels with it"              "$(say nested-out)"   "3 123 99"
ok "two live buffers, each with its own count"  "$(say two-in)"       "0 41"
ok "an index inside one and outside the other"  "$(say two-mixed)"    "3 123"
ok "one read-only buffer at two positions"      "$(say twice-ro)"     "0 22"
ok "a write through a borrowed inout buffer"    "$(say store-ok)"     "0 7 99"
ok "a value with no i32 fails BEFORE the write" "$(say store-narrow)" "2 7 99"
ok "and an out-of-bounds store writes nothing"  "$(say store-bounds)" "3 7 99"
ok "INT64_MIN is an ordinary i64 element"       "$(say i64-min)"      "0 -9223372036854775808"
ok "a count past INT64_MAX is ARGUMENT"         "$(say i64-huge)"     "1 123"
ok "an internal boolean helper drives a branch" "$(say bool-in)"      "0 11"
ok "and its other arm"                          "$(say bool-out)"     "0 -1"

# THE ORACLE IS CRuby, RUN HERE, not a constant I worked out by hand. The
# defect this covers produced a wrong answer with an OK status, so the check
# has to come from something other than the compiler under test.
RUBY="${RUBY:-ruby}"
if "$ROOT/tools/oracle/gate" tests/doom-core/borrowed-calls.sh order; then
  rb=$("$RUBY" -e '
    load ARGV[0]
    b = [1]
    r = dc_order(b, 1)
    print "0 #{r} #{b[0]}"
  ' "$FIX/src/dc_order.rb")
  ok "the element read in \`buf[0] += rhs(buf)\` happens before the call" \
                                                  "$(say order)"        "$rb"
  ok "and CRuby's own answer is the one recorded"  "$rb"                "0 6 6"
fi

echo "== the symbols the kernels export =="
# One entry per object and nothing else: a helper is internal, and a borrowed
# count is not a symbol at all.
#
# THE SYMBOL PREFIX IS THE PLATFORM'S, NOT OURS. Mach-O gives every symbol a
# leading underscore and ELF does not, so an expectation spelled
# `spinel_core_dc_pick` is an ELF expectation and fails on macOS while the rule
# it checks holds -- exactly one symbol came back, spelled the platform's way.
# Derive the prefix instead of keying on a platform name, and derive it from a
# SEPARATE object built by the C compiler rather than from the objects under
# test: agreement between two outputs of one generator is not an oracle.
printf 'int spinel_core_prefix_probe(void) { return 0; }\n' > "$W/prefix.c"
"$CC_BIN" -c "$W/prefix.c" -o "$W/prefix.o" 2> "$W/prefix.err" ||
  die "could not build the symbol-prefix probe: $(cat "$W/prefix.err")"
SYMPFX=$("$NM_BIN" --defined-only -g "$W/prefix.o" | awk '{print $NF}' |
         sed -n 's/\(.*\)spinel_core_prefix_probe$/\1/p' | head -1)
case $SYMPFX in
  "" | _) : ;;
  *) die "the C compiler gives symbols the prefix '$SYMPFX', which this check " \
         "does not know how to read" ;;
esac
echo "  (this platform prefixes symbols with '$SYMPFX')"
for stem in dc_pick dc_nested dc_two; do
  syms=$("$NM_BIN" --defined-only -g "$W/$stem.o" | awk '{print $NF}' | sort | tr '\n' ' ')
  ok "$stem exports only its entry" "$syms" "${SYMPFX}spinel_core_$stem "
done

echo "== what it refuses, by name =="
refusal() { # stem pattern label
  build "$1" refuse
  ok "  $1 is refused" "$(cat "$W/$1.rc")" 1
  want "$3" "$W/$1.err" "$2"
}
refusal readonly_write "readonly-write: data is borrowed read-only here" \
  "a callee writing a read-only borrow"
refusal dup_mutable "duplicate-mutable-argument: data is passed to dc_pair at argument 0 and argument 1" \
  "one writable buffer under two names"
refusal escape "buffer-escape: this returns a borrowed buffer" \
  "a borrowed address leaving the call that lent it"
refusal rebind "buffer-rebound: data holds a borrowed buffer" \
  "rebinding the name a borrow arrived under"
refusal buffer_arith "buffer-arithmetic:.*has a buffer operand" \
  "arithmetic on an address"
refusal recursive "recursive-call: recursive call cycles are not supported" \
  "a recursive call cycle"
refusal unknown_call "unresolved-call: dc_absent" \
  "a call to something outside the closure"
refusal bool_result "the entry's result is bool, and the contract exports an integer" \
  "a boolean exported under an integer contract"
# The pair for the last one: a boolean INSIDE the closure is admitted, which
# the dc_bool lane above already compiled and ran.
# `dc_bool.err` carries the kernel's own "wrote <path>" line, and that path
# has the word bool in it, so the pattern has to name the refusal and not the
# word: a loose pattern here passed for the wrong reason until it was measured.
reject "an internal boolean is not refused" "$W/dc_bool.err" 'not-eligible|not-lowerable'

echo "== the entry's buffer context =="
# dc_ctx_sum is handed the entry's `a` on every call: it takes the context
# and no pointer or bound of its own. dc_ctx_pick is handed `a` and `b`: it
# keeps both. Worked by hand: a = 1 2 3, b = 10 20 gives 6 + 1 + 20 * 100 =
# 2007; with a two long, dc_ctx_sum's third read is BOUNDS (3), so the bound
# it read from the context is a's.
"$KERNEL" "$FIX/src/dc_ctx.contract" --root "$FIX" --typedump "$READER" -o "$W/dc_ctx.o" --header "$W/dc_ctx.h" \
  --emit-mlir "$W/dc_ctx.mlir" --clang "$CC_BIN" > "$W/dc_ctx.err" 2>&1 && rc=0 || rc=$?
ok "dc_ctx compiles" "$rc" 0
ok "dc_ctx_sum takes the context and the result pointer, no pointer and bound of its own" \
   "$(grep -o 'func.func private @sp_dc_ctx_sum([^)]*)' "$W/dc_ctx.mlir" | sed 's/%arg[0-9]*: //g')" \
   "func.func private @sp_dc_ctx_sum(i64, !llvm.ptr, !llvm.ptr)"
ok "dc_ctx_pick, handed two buffers, keeps its pointer and bound" \
   "$(grep -o 'func.func private @sp_dc_ctx_pick([^)]*)' "$W/dc_ctx.mlir" | sed 's/%arg[0-9]*: //g')" \
   "func.func private @sp_dc_ctx_pick(!llvm.ptr, i64, i64, !llvm.ptr)"
cat > "$W/ctx.c" <<'C'
#include <inttypes.h>
#include <stdio.h>
#include "dc_ctx.h"
int main(void)
{
	int64_t a[3] = {1, 2, 3}, b[2] = {10, 20}, r = 77;
	int32_t st = spinel_core_dc_ctx(a, 3, b, 2, &r);
	printf("%d %" PRId64 "|", (int)st, r);
	r = 77;
	st = spinel_core_dc_ctx(a, 2, b, 2, &r);
	printf("%d %" PRId64 "\n", (int)st, r);
	return 0;
}
C
if "$CC_BIN" -I"$W" "$W/ctx.c" "$W/dc_ctx.o" -o "$W/ctx" > "$W/ctx.build" 2>&1; then
  ok "through the context: 2007, and BOUNDS with a two long (the result untouched)" "$("$W/ctx")" "0 2007|3 77"
else
  echo "  FAIL the context harness did not build"; sed 's/^/        /' "$W/ctx.build" | head -6; fail=$((fail + 1))
fi

echo "== under the address sanitiser =="
# The bounds check is what stands between an index and the storage. Building
# the harness with ASan and running the same cases is what says the refusals
# above are refusing before the access, not after it.
if "$CC_BIN" -fsanitize=address -I"$W" "$W/h.c" $objs -o "$W/h.asan" > "$W/asan.build" 2>&1; then
  if "$W/h.asan" > "$W/asan.out" 2>&1; then
    ok "the same cases run clean under ASan" "$(say pick-out)" "$(grep '^pick-out ' "$W/asan.out" | cut -d' ' -f2-)"
    reject "and it reports nothing"           "$W/asan.out" 'AddressSanitizer'
  else
    echo "  FAIL the ASan build did not run"; sed 's/^/        /' "$W/asan.out" | head -6; fail=$((fail + 1))
  fi
else
  echo "  SKIP no ASan runtime for $CC_BIN" >&2
fi

echo "borrowed-calls: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" -eq 0 ] || exit 1
