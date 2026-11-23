#!/bin/sh
#
# tests/core-stack/run.sh -- decision 0010 step 2: the stack budget.
#
#   LLVM_PREFIX=/opt/llvm-23.1.1 sh tests/core-stack/run.sh
#
# THIS SCRIPT IS 0010's PROOF-OF-CONCEPT ACCEPTANCE AND NOTHING ELSE. Its four
# items are the record's, quoted where they are checked:
#
#   1. "On Debian, A equals B per function."  A is the frame-size diagnostic
#      the report uses; B is ELF .llvm_stack_sizes from a side compile of the
#      SAME optimised IR. B is ELF-only, so this item skips off ELF.
#   2. "On both hosts, a runtime high-water measurement on a painted stack
#      stays within the static kernel_stack."
#   3. "A deliberately large frame and a deep acyclic call chain are reported
#      correctly."
#   4. "A dynamic alloca is refused under realtime."
#
# and the two branches of the inequality, which the proof of concept has to
# show and no profile in this tree can supply numbers for. The fixture flags
# that do supply them are checked here to be unused everywhere else.
#
# KERNEL, STACK_TOOL, SPINEL_TYPEDUMP, CLANG (or LLVM_PREFIX) and RUBY select
# the tools. REAL_IR, a directory of .bc files left by --emit-optimised-ir,
# adds item 1 over real entries; without it that part skips. REQUIRE_ALL=1
# turns a skip into a failure.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/tests/core-stack"
FIX="$HERE/fixtures"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
STACK_TOOL="${STACK_TOOL:-$ROOT/tools/mlir/native/build/bin/spinel-core-stack}"
READER="${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"
RUBY="${RUBY:-ruby}"

die() { echo "core-stack: $*" >&2; exit 1; }
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL (build tools/mlir/native first)"
[ -x "$STACK_TOOL" ] || die "no spinel-core-stack at $STACK_TOOL (build tools/mlir/native first)"
[ -x "$READER" ] || die "no contract reader at $READER (build tools/contract or set SPINEL_TYPEDUMP)"
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else die "set LLVM_PREFIX (or CLANG) to the official LLVM 23.1.1; this script refuses to guess"
fi
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"
READELF="${READELF:-$(dirname "$CC_BIN")/llvm-readelf}"
# The object's format comes from a reader that answers on both formats:
# llvm-readelf --stack-sizes prints no Format: line on ELF, so it cannot be
# asked what it is looking at. llvm-readobj --file-headers prints
# "Format: elf64-x86-64" there and "Format: Mach-O arm64" here.
READOBJ="${READOBJ:-$(dirname "$CC_BIN")/llvm-readobj}"

W=$(mktemp -d "${TMPDIR:-/tmp}/core-stack.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0; skip=0
skips=""
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1));
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
skipped() { echo "  SKIP $1"; skip=$((skip + 1)); skips="$skips  - $1
"; }
# NOT APPLICABLE IS NOT A SKIP. A skip is required execution that did not happen
# and REQUIRE_ALL turns it into a failure; this is an item the record does not
# ask of this host at all. 0010 says "ON DEBIAN, A equals B per function", so off
# ELF there is nothing owed. 0008 task 9's rule that a documented nonapplicable
# row is not a pass holds in the other direction too: it is not a failure either.
# Counted on its own line so a run says what it did not owe, and left alone by
# REQUIRE_ALL.
na=0; nas=""
notapplicable() { echo "  N/A  $1"; na=$((na + 1)); nas="$nas  - $1
"; }

# The analysis over one IR, as the report runs it, reduced to one field.
field() { # ir profile key [extra args...]
  ir=$1; profile=$2; key=$3; shift 3
  "$STACK_TOOL" "$ir" --clang "$CC_BIN" --profile "$profile" "$@" 2>/dev/null |
    sed -n "s/^$key: //p"
}

echo "core-stack: building the fixture entries"
"$RUBY" "$ROOT/tests/core-report/contracts.rb" --fixture "$FIX/stack.rb" \
  --root-name stack.rb --out "$W" st_deep st_wide st_leaf
cp "$FIX/stack.rb" "$W/stack.rb"
for e in st_deep st_wide st_leaf; do
  "$KERNEL" "$W/$e.contract" --root "$W" -o "$W/$e.o" --header "$W/$e.h" \
    --clang "$CC_BIN" --typedump "$READER" \
    --emit-optimised-ir "$W/$e.bc" > "$W/$e.build.log" 2>&1 ||
    die "the fixture entry $e did not build; see $W/$e.build.log"
done

# ---------------------------------------------------------------------------
echo "core-stack: 1. A equals B per function"
# B is ELF-only. Detect it by asking for the section rather than by guessing
# from the platform name.
ab() { # name ir
  name=$1; ir=$2
  "$CC_BIN" -O2 -Wno-override-module -fstack-size-section \
    -Xclang -disable-llvm-passes -c "$ir" -o "$W/$name.b.o" 2>/dev/null ||
    { skipped "$name: the side compile for method B failed"; return; }
  if ! "$READELF" --stack-sizes "$W/$name.b.o" > "$W/$name.b.txt" 2>/dev/null; then
    skipped "$name: no .llvm_stack_sizes reader here, so method B has no answer"
    return
  fi
  # AND SUCCEEDING IS NOT THE SAME AS ANSWERING. llvm-readelf --stack-sizes on a
  # Mach-O object EXITS 0 and prints a header with no rows, so the guard above
  # cannot see it: measured on Darwin arm64, exit 0, 70 bytes, zero rows
  # matching the parser below. Without this the empty B is compared against a
  # populated A and the item fails as "A != B", which is exactly what a broken
  # frame-size diagnostic would print -- a platform fact wearing the clothes of
  # a content defect, in the suite whose job is to catch that defect.
  #
  # SO THE DECISION IS ON THE OBJECT'S FORMAT, not on the reader's exit status
  # and not on the row count: an ELF object whose .llvm_stack_sizes is EMPTY
  # must still reach the comparison and still fail.
  #
  # AND THE FORMAT IS TAKEN FROM A READER THAT ANSWERS ON BOTH. Reading it from
  # --stack-sizes was wrong and inverted the item on ELF: that output begins
  # "Stack Sizes:" and carries NO Format: line at all, so the empty answer --
  # which this file had treated as "unknown" -- was the ELF case, and item 1
  # went not-applicable on the only host it runs on. Measured by the Debian implementer at
  # 31ef5a6: six N/A on Debian, where six passes were owed.
  fmt=$("$READOBJ" --file-headers "$W/$name.b.o" 2>/dev/null |
          sed -n 's/^Format: *//p' | head -1)
  case $fmt in
    *[Ee][Ll][Ff]*) : ;;
    # AN UNDETERMINED FORMAT FAILS, IT IS NEVER NOT-APPLICABLE. Not-applicable
    # is a positive claim -- this object is Mach-O and 0010 says "on Debian" --
    # so it is reachable only when a non-ELF format was positively identified.
    # A reader that named nothing is an instrument that did not answer, and an
    # instrument that did not answer must fail closed: the alternative is how
    # this item stopped running on ELF without going red.
    "") ok "$name: the object format could be read" "no format from $READOBJ" "a format"
        return ;;
    *)  notapplicable "$name: method B is ELF-only and this object is $fmt"
        return ;;
  esac
  # A is the diagnostic's frame: the tool's frame less the call frame it added
  # (items 5 and 6), which neither A's diagnostic nor B's section contains
  "$STACK_TOOL" "$ir" --clang "$CC_BIN" --profile hosted-stage2 2>/dev/null |
    awk '$1 == "unreserved" { u[$2] = $3 } $1 == "frame" { f[$2] = $3 }
         END { for (n in f) print n, (f[n] == "unknown" ? f[n] : f[n] - u[n]) }' |
    sort > "$W/$name.a.txt"
  "$RUBY" -e '
    File.readlines(ARGV[0]).each do |line|
      m = line.match(/^\s*(0x[0-9a-fA-F]+|\d+)\s+(\S+)\s*$/) or next
      size = m[1].start_with?("0x") ? m[1].to_i(16) : m[1].to_i
      puts "#{m[2]} #{size}"
    end
  ' "$W/$name.b.txt" | sort > "$W/$name.bn.txt"
  count=$(wc -l < "$W/$name.a.txt" | tr -d ' ')
  if [ "$count" = 0 ]; then
    ok "$name: method A reported at least one function" "none" "some"
    return
  fi
  if cmp -s "$W/$name.a.txt" "$W/$name.bn.txt"; then
    ok "$name: A == B over $count functions" yes yes
  else
    echo "  FAIL $name: A != B"; diff -u "$W/$name.a.txt" "$W/$name.bn.txt" | sed 's/^/    /'
    fail=$((fail + 1))
  fi
}
for e in st_deep st_wide st_leaf; do ab "$e" "$W/$e.bc"; done
# The same item over real entries, when a directory of their saved IR is given.
if [ -n "${REAL_IR:-}" ]; then
  found=0
  for ir in "$REAL_IR"/*.bc; do
    [ -e "$ir" ] || continue
    found=1
    ab "real:$(basename "$ir" .bc)" "$ir"
  done
  [ "$found" = 1 ] || skipped "REAL_IR names no .bc file, so no real entry was compared"
else
  skipped "REAL_IR is unset, so A == B was checked on the fixtures only"
fi

# ---------------------------------------------------------------------------
echo "core-stack: 2. a painted-stack run stays within the static figure"
deep_static=$(field "$W/st_deep.bc" hosted-stage2 kernel_stack)
[ -n "$deep_static" ] || die "the fixture st_deep has no kernel_stack to check against"
if "$CC_BIN" -O2 -Wall -Wextra -I"$W" -o "$W/highwater" "$HERE/highwater.c" \
     "$W/st_deep.o" -lpthread > "$W/highwater.build.log" 2>&1; then
  if "$W/highwater" "$deep_static" > "$W/highwater.log" 2>&1; then
    hw=$(sed -n 's/^runtime_high_water //p' "$W/highwater.log")
    ctrl=$(sed -n 's/^control_mark //p' "$W/highwater.log")
    ok "the run wrote $hw bytes, within the static $deep_static" yes yes
    ok "the harness saw its own 4096-byte control (mark $ctrl)" yes yes
  else
    echo "  FAIL the painted-stack run:"; sed 's/^/    /' "$W/highwater.log"
    fail=$((fail + 1))
  fi
  # AND IT CAN FAIL. A budget one byte below what the run measured must be
  # refused, or the check above is a print statement.
  if [ -n "${hw:-}" ] && [ "$hw" -gt 1 ]; then
    if "$W/highwater" $((hw - 1)) > /dev/null 2>&1; then
      ok "a budget one byte below the measurement is refused" no yes
    else
      ok "a budget one byte below the measurement is refused" yes yes
    fi
  fi
else
  skipped "the painted-stack harness did not build; see $W/highwater.build.log"
fi

# ---------------------------------------------------------------------------
echo "core-stack: 3. a large frame and a deep acyclic chain"
# THE SHAPE IT GOT, NOT THE SOURCE'S. The chain is eight levels in the fixture
# and the inliner decides how many survive; what must hold is that several do,
# that they are distinct frames, and that the total is the frames plus one
# overhead per edge. A build that flattened the chain fails here, which is the
# check 0010 asks for -- the graph is the final one or it is not a graph.
deep_path=$(field "$W/st_deep.bc" hosted-stage2 worst_path)
deep_frames=$(printf '%s\n' "$deep_path" | wc -w | tr -d ' ')
if [ "$deep_frames" -ge 4 ]; then
  ok "the deep chain kept $deep_frames frames on the worst path" yes yes
else
  ok "the deep chain kept at least 4 frames on the worst path" "$deep_frames" ">=4"
fi
deep_total=$(field "$W/st_deep.bc" hosted-stage2 frame_total)
deep_over=$(field "$W/st_deep.bc" hosted-stage2 call_overhead)
deep_ks=$(field "$W/st_deep.bc" hosted-stage2 kernel_stack)
ok "kernel_stack is the frames plus one overhead per edge" \
   "$deep_ks" "$((deep_total + (deep_frames - 1) * deep_over))"
wide_frames=$(field "$W/st_wide.bc" hosted-stage2 worst_path | wc -w | tr -d ' ')
wide_ks=$(field "$W/st_wide.bc" hosted-stage2 kernel_stack)
ok "the large-frame entry is one frame" "$wide_frames" 1
if [ "$wide_ks" -gt 64 ]; then
  ok "its frame is large ($wide_ks bytes)" yes yes
else
  ok "its frame is larger than 64 bytes" "$wide_ks" ">64"
fi
# An entry that needs no frame at all is a zero, not an absent measurement.
ok "an entry with no frame reports zero, not unknown" \
   "$(field "$W/st_leaf.bc" hosted-stage2 evaluated):$(field "$W/st_leaf.bc" hosted-stage2 kernel_stack)" \
   "true:0"

# ---------------------------------------------------------------------------
echo "core-stack: 4. a dynamic alloca is refused under realtime"
ok "realtime fails it" \
   "$(field "$FIX/dynamic-alloca.ll" realtime verdict)" fail
ok "hosted-stage2 reaches no verdict rather than passing it" \
   "$(field "$FIX/dynamic-alloca.ll" hosted-stage2 evaluated)" false
ok "and says why" \
   "$("$STACK_TOOL" "$FIX/dynamic-alloca.ll" --clang "$CC_BIN" --profile realtime 2>/dev/null |
      grep -c 'admits no dynamic stack allocation')" 1

# ---------------------------------------------------------------------------
echo "core-stack: 5. thumb: a call frame codegen did not reserve is counted, once"
# A call with N pointer arguments passes N - 4 of them on the stack. At 520
# that area (2064 bytes) is past the 2047 the Arm backend reserves in the
# frame, so clang's own frame size leaves it out and the method must add it;
# at 500 (1984 bytes) the frame holds it, and adding it again would count it
# twice. The callee is declared only, attested at 0.
calls() { # n: a caller passing n pointers to a declared callee
  awk -v n="$1" 'BEGIN {
    printf "void callee("; for (i = 1; i <= n; i++) printf "%sint *a%d", (i > 1 ? ", " : ""), i; print ");"
    printf "void caller(int *p) { callee("; for (i = 1; i <= n; i++) printf "%sp + %d", (i > 1 ? ", " : ""), i; print "); }" }'
}
THUMB="--target=thumbv8m.main-none-eabi"
for n in 500 520; do
  calls $n > "$W/calls$n.c"
  "$CC_BIN" $THUMB -O2 -S -emit-llvm "$W/calls$n.c" -o "$W/calls$n.ll" &&
    "$CC_BIN" $THUMB -O2 -fstack-usage -c "$W/calls$n.c" -o "$W/calls$n.o" ||
    die "the thumb call fixture $n did not compile"
  "$STACK_TOOL" "$W/calls$n.ll" --clang "$CC_BIN" --profile hosted-stage2 \
    --attested callee=0 -- $THUMB > "$W/calls$n.out" 2>&1 || true
done
su520=$(cut -f2 "$W/calls520.su"); su500=$(cut -f2 "$W/calls500.su")
ok "520 arguments: the unreserved call frame is the 516 stacked pointers" \
   "$(sed -n 's/^unreserved caller //p' "$W/calls520.out")" 2064
ok "520 arguments: kernel_stack is clang's frame ($su520) plus that area" \
   "$(sed -n 's/^kernel_stack: //p' "$W/calls520.out")" $((su520 + 2064))
ok "500 arguments: no unreserved call frame is reported" \
   "$(grep -c '^unreserved caller' "$W/calls500.out")" 0
ok "500 arguments: kernel_stack is clang's frame ($su500), the area not counted twice" \
   "$(sed -n 's/^kernel_stack: //p' "$W/calls500.out")" "$su500"
ok "the method's control was found on this run" \
   "$(sed -n 's/^unreserved_control: //p' "$W/calls520.out" | awk '{ print ($1 >= 2048) }')" 1

# ---------------------------------------------------------------------------
echo "core-stack: 6. x86-64: a call frame built with pushes is counted, once"
# X86CallFrameOptimization pushes a call's stack arguments just before it
# (8 bytes each past the sixth), and clang's own frame size leaves them out.
# With 8 and 12 pointer arguments the frame must gain 16 and 48; at 12 the
# prologue's pushes run straight into the arguments', and only the latter
# count. With 6, all in registers and the result used, nothing is pushed and
# nothing may be added.
X86="--target=x86_64-linux-gnu"
pushcalls() { # n: as calls, with the result used so the call is not a tail call
  awk -v n="$1" 'BEGIN {
    printf "int callee("; for (i = 1; i <= n; i++) printf "%sint *a%d", (i > 1 ? ", " : ""), i; print ");"
    printf "int caller(int *p) { return callee("; for (i = 1; i <= n; i++) printf "%sp + %d", (i > 1 ? ", " : ""), i; print ") + 1; }" }'
}
for n in 6 8 12; do
  pushcalls $n > "$W/push$n.c"
  "$CC_BIN" $X86 -O2 -S -emit-llvm "$W/push$n.c" -o "$W/push$n.ll" &&
    "$CC_BIN" $X86 -O2 -fstack-usage -c "$W/push$n.c" -o "$W/push$n.o" ||
    die "the x86-64 call fixture $n did not compile"
  "$STACK_TOOL" "$W/push$n.ll" --clang "$CC_BIN" --profile hosted-stage2 \
    --attested callee=0 -- $X86 > "$W/push$n.out" 2>&1 || true
done
for c in 8:16 12:48; do
  n=${c%%:*}; add=${c#*:}; su=$(cut -f2 "$W/push$n.su")
  ok "$n arguments: the pushed call frame is $add bytes" \
     "$(sed -n 's/^unreserved caller //p' "$W/push$n.out")" "$add"
  ok "$n arguments: the frame is clang's ($su) plus that" \
     "$(sed -n 's/^frame caller //p' "$W/push$n.out")" $((su + add))
done
ok "6 arguments: no pushed call frame is reported" \
   "$(grep -c '^unreserved caller' "$W/push6.out")" 0
ok "6 arguments: the frame is clang's ($(cut -f2 "$W/push6.su")), nothing added" \
   "$(sed -n 's/^frame caller //p' "$W/push6.out")" "$(cut -f2 "$W/push6.su")"
ok "the x86-64 method's control was found on this run" \
   "$(sed -n 's/^unreserved_control: //p' "$W/push8.out" | awk '{ print ($1 >= 16) }')" 1

# ---------------------------------------------------------------------------
echo "core-stack: the inequality, both branches"
ok "a provision above the need passes" \
   "$(field "$W/st_deep.bc" realtime verdict \
      --fixture-stack-provision $((deep_ks + 2048)) --fixture-interrupt-reserve 1024)" \
   pass
ok "a provision below it fails" \
   "$(field "$W/st_deep.bc" realtime verdict \
      --fixture-stack-provision $((deep_ks - 1)) --fixture-interrupt-reserve 0)" \
   fail
ok "without either term the verdict is unknown, not pass" \
   "$(field "$W/st_deep.bc" realtime verdict)" unknown
"$STACK_TOOL" "$W/st_deep.bc" --clang "$CC_BIN" --profile hosted-stage2 \
  --fixture-stack-provision 4096 --fixture-interrupt-reserve 0 > /dev/null 2>&1 &&
  rc=0 || rc=$?
ok "the fixture provision is refused outside realtime" "$rc" 2

# THE MECHANISM, CHECKED. The fixture flags supply numbers no profile in this
# tree declares, so nothing but this script may pass them. A grep is what makes
# that permanent rather than a promise in a comment.
#
# The search is over the WHOLE tree, not a list of extensions, so an
# extensionless driver cannot slip past it; what is filtered out afterwards is
# the small set of files that necessarily name the flag -- the two tools that
# accept it, the code that reads it, the header that documents the mechanism,
# this lane, and 0010 itself.
allowed="tests/core-stack/run.sh
tools/mlir/native/tools/spinel-core-kernel/main.cpp
tools/mlir/native/tools/spinel-core-stack/main.cpp
tools/mlir/native/lib/Core/Report.cpp
tools/mlir/native/include/spinel-mlir/Core/StackBudget.h
docs/decisions/0010-core-resource-contract.md
docs/core/core-report.md
tests/app/cross.sh"
users=$(cd "$ROOT" && grep -rlI -e "--fixture-stack-provision" . 2>/dev/null |
        sed 's|^\./||' | grep -v '^\.git/' |
        while read -r f; do
          printf '%s\n' "$allowed" | grep -qx "$f" || printf '%s\n' "$f"
        done)
ok "nothing outside the tools that accept it passes the fixture provision" \
   "${users:-none}" none

# ---------------------------------------------------------------------------
echo
if [ -n "$skips" ]; then printf 'core-stack: skipped:\n%s' "$skips"; fi
if [ -n "$nas" ]; then printf 'core-stack: not applicable here:\n%s' "$nas"; fi
if [ "${REQUIRE_ALL:-}" = 1 ] && [ "$skip" -gt 0 ]; then
  echo "core-stack: REQUIRE_ALL=1 and $skip check(s) did not run"
  fail=$((fail + skip))
fi
echo "core-stack: $((pass + fail)) checked, $pass pass, $fail fail, $skip skipped, $na not applicable"
[ "$fail" = 0 ] || exit 1
