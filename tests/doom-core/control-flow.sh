#!/bin/sh
#
# tests/doom-core/control-flow.sh — decision 0008 task 4.
#
# The forms the measured DOOM closure needs, and the ones that stay out.
# docs/core/doom-stage2-language.md states each with its position and its exact
# refusal, and was written before any of it was coded; this measures the same
# list. A refusal is checked by ITS OWN category, because everything that fails
# here exits nonzero.
#
# Where Ruby is the reference -- what `break` and `next` do, what short
# circuiting evaluates -- the reference is CRuby running the same source, not a
# second table written by the same hand as the first.
#
#   LLVM_PREFIX=/opt/llvm-23.1.1 sh tests/doom-core/control-flow.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIX="$ROOT/tests/doom-core/fixtures/control-flow"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
# The kernel is told which contract reader to use. Left to itself it walks up
# from its own directory looking for one, which makes what it reads depend on
# where the binary happens to sit.
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
. "$ROOT/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"
RUBY="${RUBY:-ruby}"

die() { echo "control-flow: $*" >&2; exit 1; }
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL (build tools/mlir/native first)"
[ -d "$FIX" ] || die "no fixtures at $FIX"
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else die "set LLVM_PREFIX (or CLANG) to the official LLVM 23.1.1; this script refuses to guess"
fi
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"

W=$(mktemp -d "${TMPDIR:-/tmp}/doom-core-cf.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
want() { if grep -qE "$3" "$2"; then echo "  pass $1"; pass=$((pass + 1));
         else echo "  FAIL $1"; sed 's/^/        /' "$2" | head -6; fail=$((fail + 1)); fi; }

build() { # stem dir
  "$KERNEL" "$FIX/$2/$1.contract" --root "$FIX" --typedump "$READER" -o "$W/$1.o" --header "$W/$1.h" \
    --clang "$CC_BIN" > "$W/$1.err" 2>&1 && echo 0 > "$W/$1.rc" || echo $? > "$W/$1.rc"
}

POSITIVE="if_stmt early_return break_while next_while andand oror notop opassign dc_short dc_once dc_nest"
echo "== the forms the closure needs =="
for stem in $POSITIVE; do
  build "$stem" src
  ok "$stem compiles" "$(cat "$W/$stem.rc")" 0
done

cat > "$W/h.c" <<'CEOF'
#include <stdio.h>
#include <stdint.h>
#include "if_stmt.h"
#include "early_return.h"
#include "break_while.h"
#include "next_while.h"
#include "andand.h"
#include "oror.h"
#include "notop.h"
#include "opassign.h"
#include "dc_short.h"
#include "dc_once.h"
#include "dc_nest.h"
int main(void) {
  int64_t r; int32_t s; int32_t b[2];
  for (int i = -1; i <= 1; i += 2) {
    b[0]=0; r=9; s=spinel_core_if_stmt(b,1,i,&r); printf("if_stmt %d %d %lld\n",i,s,(long long)r);
    b[0]=0; r=9; s=spinel_core_early_return(b,1,i,&r); printf("early %d %d %lld\n",i,s,(long long)r);
  }
  int probe[5] = {0, 2, 4, 99, 1};
  for (int j = 0; j < 4; j++) {
    r=9; s=spinel_core_break_while(b,1,probe[j],&r); printf("break %d %d %lld\n",probe[j],s,(long long)r);
  }
  for (int j = 0; j < 5; j++) {
    r=9; s=spinel_core_next_while(b,1,probe[j],&r); printf("next %d %d %lld\n",probe[j],s,(long long)r);
  }
  for (int i = -1; i <= 11; i += 6) {
    r=9; s=spinel_core_andand(b,1,i,&r); printf("and %d %d %lld\n",i,s,(long long)r);
    r=9; s=spinel_core_oror(b,1,i,&r);   printf("or %d %d %lld\n",i,s,(long long)r);
    r=9; s=spinel_core_notop(b,1,i,&r);  printf("not %d %d %lld\n",i,s,(long long)r);
  }
  b[0]=5; b[1]=99; r=9; s=spinel_core_opassign(b,1,0,&r);
  printf("opassign %d %lld %d %d\n",s,(long long)r,b[0],b[1]);
  r=9; s=spinel_core_opassign(b,1,1,&r);
  printf("opassign-oob %d %lld %d %d\n",s,(long long)r,b[0],b[1]);

  /* The plan's own short-circuit case. */
  int32_t c[1] = {0};
  r=9; s=spinel_core_dc_short(c,1,0,&r); printf("short0 %d %lld %d\n",s,(long long)r,c[0]);
  r=9; s=spinel_core_dc_short(c,1,1,&r); printf("short1 %d %lld %d\n",s,(long long)r,c[0]);
  int32_t z[1] = {77};
  r=9; s=spinel_core_dc_short(z,0,0,&r); printf("shortz0 %d %lld %d\n",s,(long long)r,z[0]);
  r=9; s=spinel_core_dc_short(z,0,1,&r); printf("shortz1 %d %lld %d\n",s,(long long)r,z[0]);

  /* The index expression has a side effect; the counter is the measurement. */
  int32_t e[1] = {5}; int32_t k[1] = {0};
  r=9; s=spinel_core_dc_once(e,1,k,1,0,&r);
  printf("once %d %lld %d %d\n",s,(long long)r,e[0],k[0]);

  for (int i = 0; i <= 3; i++) {
    r=9; s=spinel_core_dc_nest(b,1,i,&r); printf("nest %d %d %lld\n",i,s,(long long)r);
  }
  return 0;
}
CEOF
objs=""
for stem in $POSITIVE; do objs="$objs $W/$stem.o"; done
if "$CC_BIN" -I"$W" "$W/h.c" $objs -o "$W/h" > "$W/link.err" 2>&1; then
  echo "  pass they link into one program"; pass=$((pass + 1))
else
  echo "  FAIL they do not link"; sed 's/^/        /' "$W/link.err" | head -6; fail=$((fail + 1))
fi
"$W/h" > "$W/out" 2>&1 || true
say() { grep "^$1 " "$W/out" | head -1 | cut -d' ' -f2-; }

echo "== against CRuby, on the same source =="
if "$ROOT/tools/oracle/gate" tests/doom-core/control-flow.sh same-source; then
  # CRuby runs the SAME definitions, so the reference is the language and not a
  # table. Only the forms whose answer is a plain integer are compared this way;
  # the buffer cases are compared against the bytes below.
  cat > "$W/ref.rb" <<'RBEOF'
def if_stmt(i); r = 0; if i > 0; r = 1; end; r; end
def early_return(i); return 1 if i > 0; 0; end
def break_while(i); k = 0; while k < 10; break if k == i; k = k + 1; end; k; end
def next_while(i); k = 0; s = 0; while k < 4; k = k + 1; next if k == i; s = s + k; end; s; end
def andand(i); (i > 0) && (i < 10) ? 1 : 0; end
def oror(i); (i > 0) || (i < -10) ? 1 : 0; end
def notop(i); !(i > 0) ? 1 : 0; end
def dc_nest(i)
  o = 0; total = 0
  while o < 3
    k = 0
    while k < 3
      k = k + 1
      break if k == i
      total = total + 1
    end
    o = o + 1
  end
  total
end
[-1, 1].each { |i| puts "if_stmt #{i} 0 #{if_stmt(i)}"; puts "early #{i} 0 #{early_return(i)}" }
[0, 2, 4, 99].each { |i| puts "break #{i} 0 #{break_while(i)}" }
[0, 2, 4, 99, 1].each { |i| puts "next #{i} 0 #{next_while(i)}" }
[-1, 5, 11].each do |i|
  puts "and #{i} 0 #{andand(i)}"
  puts "or #{i} 0 #{oror(i)}"
  puts "not #{i} 0 #{notop(i)}"
end
(0..3).each { |i| puts "nest #{i} 0 #{dc_nest(i)}" }
RBEOF
  "$RUBY" "$W/ref.rb" > "$W/ref.out" 2>&1 || true
  grep -E '^(if_stmt|early|break|next|and|or|not|nest) ' "$W/out" > "$W/native.cmp" || : > "$W/native.cmp"
  if [ -s "$W/native.cmp" ] && cmp -s "$W/native.cmp" "$W/ref.out"; then
    echo "  pass $(grep -c '' "$W/ref.out") answers match CRuby line for line"; pass=$((pass + 1))
  else
    echo "  FAIL the native answers differ from CRuby"; diff "$W/ref.out" "$W/native.cmp" | head -8; fail=$((fail + 1))
  fi
fi

echo "== what the buffers say =="
ok "the \`[]+=\` form loads, computes and stores"        "$(say opassign)"     "0 6 6 99"
ok "and an out-of-bounds one stores nothing"  "$(say opassign-oob)" "3 9 6 99"
ok "a false left operand skips the right one" "$(say short0)"       "0 0 0"
ok "a true one evaluates it, once"            "$(say short1)"       "0 1 1"
ok "with a zero-length buffer, flag 0 succeeds" "$(say shortz0)"    "0 0 77"
ok "and flag 1 reaches it and is BOUNDS"        "$(say shortz1)"    "3 9 77"
ok "an index with a side effect runs once"      "$(say once)"       "0 15 15 1"

echo "== what stays out, by name =="
refusal() { # stem pattern label
  build "$1" refuse
  ok "  $1 is refused" "$(cat "$W/$1.rc")" 1
  want "$3" "$W/$1.err" "$2"
}
refusal break_value "loop-control-value: .break. carries a value" \
  "a break with a value"
refusal and_int "non-boolean-operand: .&&. has a int (left|right) operand" \
  "an integer operand of &&"
refusal not_int "non-boolean-operand: .!. has a int operand" \
  "an integer operand of !"
refusal orassign "unsupported-node: IndexOrWriteNode" \
  "conditional index assignment"
refusal ro_opassign "readonly-write: buf is borrowed read-only here" \
  "operator assignment through a read-only borrow"
build if_value src
ok "  if_value is refused" "$(cat "$W/if_value.rc")" 1
want "a conditional with no else in value position" "$W/if_value.err" \
  'implicit-nil: this branch has no value on the path not taken'

# `break` outside a loop never reaches the checker: Ruby's own parser refuses
# it first. The rule is still in the checker as defence, and this records why
# it cannot be reached from source rather than leaving it looking untested.
build break_outside refuse
ok "  break outside a loop is refused" "$(cat "$W/break_outside.rc")" 1
want "by the parser, before the checker sees it" "$W/break_outside.err" 'Invalid break'

echo "== the document says the same thing =="
DOC="$ROOT/docs/core/doom-stage2-language.md"
[ -f "$DOC" ] || die "no language document at $DOC"
want "it names the loop-control-value category"      "$DOC" 'loop-control-value'
want "and loop-control-outside-loop"                 "$DOC" 'loop-control-outside-loop'
want "and non-boolean-operand"                       "$DOC" 'non-boolean-operand'
want "it states the operator-assignment order"       "$DOC" 'bounds-check the index against the descriptor'
want "and that a failure stores nothing"             "$DOC" 'No store happens if 2, 4 or 5 fails'
want "and that the index is evaluated once"          "$DOC" 'evaluated exactly once'

echo "== a valueless branch is not a branch that never returns =="
# Mac review of 4a8ba23, reproduced verbatim. A statement-position `if` with
# no else, nested in another `if`: `dc_entry(1)` gave status OK with 0 where
# CRuby gives nil. See fixtures/control-flow/nested/README.md.
NEST="$ROOT/tests/doom-core/fixtures/control-flow/nested"
if "$KERNEL" "$NEST/dc_nested_if.contract" --root "$NEST" --typedump "$READER" -o "$W/nif.o" \
     --header "$W/nif.h" --clang "$CC_BIN" > "$W/nif.err" 2>&1; then
  echo "  FAIL the nested nil path compiled; CRuby answers nil there"
  fail=$((fail + 1))
else
  want "the nested nil path is refused" "$W/nif.err" 'not-eligible: type-evidence'
  # At the READ, which is where the program asks for a value that is not there.
  want "and it points at the read"      "$W/nif.err" 'dc_nested_if\.rb:9:2'
fi
# THE CONTROL. The same shape with the local bound first must keep compiling
# and still answer 3 -- that is what says the fix refuses the nil path rather
# than the nesting.
"$KERNEL" "$NEST/dc_nested_pre.contract" --root "$NEST" --typedump "$READER" -o "$W/npre.o" \
  --header "$W/npre.h" --clang "$CC_BIN" > "$W/npre.err" 2>&1 \
  && echo 0 > "$W/npre.rc" || echo $? > "$W/npre.rc"
ok "the same shape with the local bound first compiles" "$(cat "$W/npre.rc")" 0
cat > "$W/npre.c" <<'CEOF'
#include <stdio.h>
#include <stdint.h>
#include "npre.h"
int main(void){ int64_t r = 123; int32_t s = spinel_core_dc_pre(1, &r);
  printf("%d %lld\n", (int)s, (long long)r); return 0; }
CEOF
if "$CC_BIN" -I"$W" "$W/npre.c" "$W/npre.o" -o "$W/npre" > "$W/nprelink.err" 2>&1; then
  if "$ROOT/tools/oracle/gate" tests/doom-core/control-flow.sh nested-pre; then
    ok "and answers what CRuby answers" "$("$W/npre")" \
       "$("$RUBY" -e 'load ARGV[0]; print "0 #{dc_pre(1)}"' "$NEST/dc_nested_pre.rb")"
  fi
else
  echo "  FAIL the control did not link"; fail=$((fail + 1))
fi

echo "== a local bound only on a path not taken =="
# Mac review of 270fa5a. A local whose FIRST binding is inside a
# conditionally-evaluated expression, read afterwards: Ruby has defined it and
# reads nil. `(flag != 0) && (t = buf[0]) > 0` then `t` compiled and answered
# status OK with result 0 where CRuby gives nil -- a wrong answer under a
# successful status, with no diagnostic.
#
# The three short-circuit shapes must be REFUSED, and the three `if`/`while`
# shapes are the controls: they were ALREADY refused, which is what says the
# defect was specific to the short circuit and not general to conditional
# binding. See fixtures/control-flow/bind/README.md.
BIND="$ROOT/tests/doom-core/fixtures/control-flow/bind"
for stem in scint scint2 scif2 bindif bindelse bindwhile; do
  if "$KERNEL" "$BIND/$stem.contract" --root "$BIND" --typedump "$READER" -o "$W/$stem.o" \
       --header "$W/$stem.h" --clang "$CC_BIN" > "$W/$stem.err" 2>&1; then
    echo "  FAIL $stem compiled; a local read before its binding is not in the subset"
    fail=$((fail + 1))
  else
    want "$stem is refused, and says why" "$W/$stem.err" 'not-eligible: type-evidence'
  fi
done
# The diagnostic points at the READ, not at the binding: that is where the
# program asks for a value the subset cannot give.
want "and it points at the read"      "$W/scint.err" 'scint\.rb:5:2'

# THE FIX MUST NOT COST THE LEGITIMATE SHORT CIRCUIT. A right-hand side with a
# side effect, and one whose value is discarded, both still compile -- the
# environment join only makes a CONDITIONAL BINDING conditional.
cat > "$W/live.rb" <<'RBEOF'
def bump(count)
  count[0] = count[0] + 1
  true
end

def live(count, n_count, flag)
  (flag != 0) || bump(count)
  count[0]
end
RBEOF
cat > "$W/live.contract" <<'CEOF'
core-contract 1
root live.rb
entry live
result i64
param count buffer i64 inout count n_count
param n_count scalar u64
param flag scalar i64
CEOF
"$KERNEL" "$W/live.contract" --root "$W" --typedump "$READER" -o "$W/live.o" --header "$W/live.h" \
  --clang "$CC_BIN" > "$W/live.err" 2>&1 && echo 0 > "$W/live.rc" || echo $? > "$W/live.rc"
ok "a short circuit with a side effect still compiles" "$(cat "$W/live.rc")" 0

echo "== nil has no value, in every position the rule distinguishes =="
# Derived from `Eligibility.cpp::markPositions`, not hand-picked -- see
# fixtures/control-flow/nil/generate.rb. A VALUE position must be refused with
# a diagnostic; a STATEMENT position may be admitted, and then it must agree
# with CRuby. The second half is the half worth having: admitting a nil path
# is right when nothing reads it, and wrong only if the admitted code answers
# something CRuby does not.
NILDIR="$W/nil"
mkdir -p "$NILDIR/src"
"$RUBY" "$ROOT/tests/doom-core/fixtures/control-flow/nil/generate.rb" "$NILDIR" > "$NILDIR/list" 2>&1
ok "the sweep enumerates every crossing" "$(grep -c . "$NILDIR/list")" "24"
nil_admitted=0; nil_refused=0; nil_mismatch=0; nil_undiagnosed=0
# COUNTED SEPARATELY, because "nothing was wrong" and "nothing ran" are not
# the same answer. Mac review of b8fd8d6 found this lane reporting 53/53 with
# twelve LINK FAILURES underneath it: the link was an `if` with no `else`, so
# a failure skipped the CRuby comparison and incremented nothing. Every
# assertion still passed. That is the shape this suite exists to catch, and it
# was in the suite.
nil_compared=0; nil_unlinked=0
# The admitted ones are compared with CRuby only on the owner's instruction.
if "$ROOT/tools/oracle/gate" tests/doom-core/control-flow.sh nil-sweep; then nilref=1; else nilref=0; fi
for c in "$NILDIR"/src/*.contract; do
  stem=$(basename "$c" .contract)
  if "$KERNEL" "$c" --root "$NILDIR" --typedump "$READER" -o "$NILDIR/$stem.o" --header "$NILDIR/$stem.h" \
       --clang "$CC_BIN" > "$NILDIR/$stem.err" 2>&1; then
    nil_admitted=$((nil_admitted + 1))
    cat > "$NILDIR/$stem.c" <<CEOF
#include <stdio.h>
#include <stdint.h>
#include "$stem.h"
int main(void){ for (int f=0; f<=1; f++){ int64_t b[1]={3}; int64_t r=-424242;
  int32_t s = spinel_core_$stem(b,1,f,&r);
  printf("%d %d %lld %lld\n", f,(int)s,(long long)r,(long long)b[0]); } return 0; }
CEOF
    if "$CC_BIN" -I"$NILDIR" "$NILDIR/$stem.c" "$NILDIR/$stem.o" -o "$NILDIR/$stem.bin" \
         >> "$NILDIR/$stem.err" 2>&1; then
      "$NILDIR/$stem.bin" > "$NILDIR/$stem.native" 2>&1
      if [ "$nilref" = 1 ]; then
        "$RUBY" -e '
          load ARGV[0]
          stem = File.basename(ARGV[0], ".rb")
          [0, 1].each do |f|
            b = [3]
            r = send(stem, b, 1, f)
            shown = r.nil? ? "NIL" : (r == true ? "TRUE" : (r == false ? "FALSE" : r))
            puts "#{f} 0 #{shown} #{b[0]}"
          end
        ' "$NILDIR/src/$stem.rb" > "$NILDIR/$stem.ruby" 2>&1
        nil_compared=$((nil_compared + 1))
        diff -q "$NILDIR/$stem.native" "$NILDIR/$stem.ruby" > /dev/null || {
          nil_mismatch=$((nil_mismatch + 1)); echo "        $stem differs from CRuby"; }
      fi
    else
      nil_unlinked=$((nil_unlinked + 1))
      echo "        $stem compiled but did not link"
      sed 's/^/          /' "$NILDIR/$stem.err" | tail -2
    fi
  else
    nil_refused=$((nil_refused + 1))
    grep -qE 'not-eligible: [a-z-]+|not-lowerable: .*unsupported-node' "$NILDIR/$stem.err" \
      || nil_undiagnosed=$((nil_undiagnosed + 1))
  fi
done
ok "every value position is refused"        "$nil_refused"      "12"
ok "and none of them refused silently"      "$nil_undiagnosed"  "0"
ok "every statement position is admitted"   "$nil_admitted"     "12"
# THE COMPARISON MUST HAVE RUN. Without this, a link failure leaves
# `nil_mismatch` at 0 and the line below passes on twelve runs that never
# happened.
if [ "$nilref" = 1 ]; then
  ok "and every admitted one was actually run" "$nil_compared"    "12"
  ok "and every admitted one answers CRuby"    "$nil_mismatch"    "0"
fi
ok "none failed to link"                     "$nil_unlinked"    "0"

echo "control-flow: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" -eq 0 ] || exit 1
