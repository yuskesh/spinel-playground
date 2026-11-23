#!/bin/sh
#
# tests/core-boundary/arithmetic.sh — the arithmetic reference and refusal
# cases for decision 0007 task 2, written BEFORE the checked scalar mode
# exists.
#
#   BOUNDARY=<path to spinel-core-boundary> tests/core-boundary/arithmetic.sh
#
# Four lanes:
#
#   1. the language oracle (oracle.rb): the case table is well formed and in
#      bijection with the fixtures, CRuby agrees with every declared value,
#      and the declared status and reason agree with the domain rule derived
#      from CRuby's mathematical-integer result.
#   2. mutation controls on that oracle.  Each is one cell, and each is a
#      wrong answer somebody would plausibly ship -- C truncation for `/`, the
#      C sign for `%`, decision 0007's shift count rule.  If the
#      oracle still passes with one of these in the table, lane 1 proves
#      nothing.
#   3. the boundary tool accepts a contract for every case, which is what
#      binds the table's entry names and arities to the Ruby definitions.
#   4. execution.  There is no checked scalar mode yet, so no case can be run;
#      that count is printed, not hidden, and REQUIRE_EXECUTION=1 turns an
#      unexecuted case into a failure.  Task 2 sets it.
#
# Nothing here compiles or runs a kernel.  Until lane 4 executes, this file
# establishes what the answers must be, not that anything produces them.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/tests/core-boundary"
FIX="$HERE/fixtures/arithmetic"
BOUNDARY="${BOUNDARY:-$ROOT/tools/mlir/native/build/bin/spinel-core-boundary}"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
CHECK="${CORE_CHECK:-$ROOT/tools/mlir/native/build/bin/spinel-core-check}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$KERNEL"
source_stamp kernel "$CHECK"
CC_BIN="${CC:-${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/clang}"

die() { echo "arithmetic: $*" >&2; exit 1; }
[ -f "$FIX/cases.tsv" ] || die "no case table at $FIX/cases.tsv"
[ -x "$BOUNDARY" ] || die "no spinel-core-boundary at $BOUNDARY (build it first)"
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"
RUBY="${RUBY:-ruby}"
command -v "$RUBY" >/dev/null 2>&1 || die "no ruby at '$RUBY'; the language oracle needs one"
"$RUBY" -e 'exit 0' >/dev/null 2>&1 || die "'$RUBY' does not run"
echo "arithmetic: ruby is $("$RUBY" -e 'print RUBY_VERSION') at $(command -v "$RUBY")"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/core-arith.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
pass=0; fail=0; oracle_n=0

echo "== the language oracle =="
if "$ROOT/tools/oracle/gate" tests/core-boundary/arithmetic.sh language-oracle; then
  if "$RUBY" "$HERE/oracle.rb" > "$WORK/oracle.log" 2>&1; then
    grep '^==' "$WORK/oracle.log" | sed 's/^/  /'
    oracle_line=$(tail -1 "$WORK/oracle.log")
    echo "  $oracle_line"
    oracle_n=$(echo "$oracle_line" | awk '{ print $2 }')
    pass=$((pass + 1))
  else
    echo "  FAIL the oracle rejected the case table:"
    grep 'FAIL' "$WORK/oracle.log" | sed 's/^/      /' | head -10
    fail=$((fail + 1))
  fi
fi

echo "== mutation controls: the oracle must reject each of these =="
if "$ROOT/tools/oracle/gate" tests/core-boundary/arithmetic.sh mutation-controls; then mutations=1; else mutations=0; fi
# Each mutation rewrites CELLS OF ONE LINE of cases.tsv and nothing else.  The
# number of cells is declared per mutation and the number of changed lines is
# checked, so a mutation that silently matched nothing -- or that rewrote the
# table wholesale -- cannot pass as a refusal.
#
# Columns: 1 id, 2 source, 3 entry, 4 op, 5 result, 6 args, 7 status, 8 value,
# 9 reason.
mutate() {
  _label=$1; _id=$2; _want=$3; shift 3
  _dir="$WORK/mut"
  rm -rf "$_dir"
  mkdir -p "$_dir/fixtures"
  cp -R "$FIX" "$_dir/fixtures/arithmetic"
  cp "$HERE/oracle.rb" "$_dir/oracle.rb"

  _spec=$*
  _cells=$#
  if ! awk -F'\t' -v OFS='\t' -v id="$_id" -v spec="$_spec" '
    BEGIN { n = split(spec, pairs, " ") }
    $1 == id {
      for (i = 1; i <= n; i++) {
        c = index(pairs[i], ":")
        $(substr(pairs[i], 1, c - 1)) = substr(pairs[i], c + 1)
      }
      hit++
    }
    { print }
    END { if (hit != 1) exit 3 }
  ' "$FIX/cases.tsv" > "$_dir/fixtures/arithmetic/cases.tsv"; then
    echo "  FAIL $_label: cases.tsv holds no single case named $_id"
    fail=$((fail + 1)); rm -rf "$_dir"; return
  fi

  _lines=$(diff "$FIX/cases.tsv" "$_dir/fixtures/arithmetic/cases.tsv" | grep -c '^>' || true)
  if [ "$_lines" -ne 1 ]; then
    echo "  FAIL $_label changed $_lines line(s); a mutation control must change exactly one"
    fail=$((fail + 1)); rm -rf "$_dir"; return
  fi
  # The table edits above are checked either way; running the oracle over
  # them is the owner's instruction.
  [ "$mutations" = 1 ] || { rm -rf "$_dir"; return 0; }

  if "$RUBY" "$_dir/oracle.rb" > "$_dir/log" 2>&1; then
    echo "  FAIL $_label was accepted; the oracle does not check this"
    fail=$((fail + 1)); rm -rf "$_dir"; return
  fi
  # A non-zero exit is NOT the check. The oracle exits non-zero when it cannot
  # run at all -- a Ruby that does not understand it, a missing fixture -- and
  # every mutation would then "pass" while nothing was compared. Measured: a
  # system ruby that failed to start scored all six as rejections.
  #
  # So two things are required, both declared: the oracle must have RUN TO THE
  # END (it prints its own summary line last), and its refusal must be the one
  # this mutation intends, named per mutation rather than "some FAIL".
  if ! grep -q '^oracle: .* checked,' "$_dir/log"; then
    echo "  FAIL $_label: the oracle did not run to completion, so nothing was compared:"
    sed 's/^/      /' "$_dir/log" | head -4
    fail=$((fail + 1)); rm -rf "$_dir"; return
  fi
  if ! grep -q "FAIL .*$_want" "$_dir/log"; then
    echo "  FAIL $_label was rejected, but not for its own reason (wanted \"$_want\"):"
    grep 'FAIL' "$_dir/log" | sed 's/^ *FAIL */      /' | head -3
    fail=$((fail + 1)); rm -rf "$_dir"; return
  fi
  echo "  pass $_label ($_cells cell(s), 1 line) is rejected:"
  grep -m1 "FAIL .*$_want" "$_dir/log" | sed 's/^ *FAIL */      /'
  pass=$((pass + 1))
  rm -rf "$_dir"
}

# C truncation instead of Ruby floor division: -7 / 2 is -3 in C and -4 here.
mutate "C truncation for /"         fdiv-np \
       "fdiv-np: the table says -3, CRuby says -4"           8:-3
# The C sign for the remainder: 7 % -2 is 1 in C and -1 here.
mutate "the C sign for %"           rem-pn \
       "rem-pn: the table says 1, CRuby says -1"             8:1
# Decision 0007's shift count rule, which decision 0042's S1 replaced: -1 >> 64
# is -1 in Ruby, and a table that calls the count out of range is wrong.
mutate "the 0007 count rule"        shr-count-64 \
       "shr-count-64: the table blames shift-range"          7:arithmetic 8:- 9:shift-range
# Refusing every paired remainder rather than special-casing INT64_MIN % -1.
mutate "refusing INT64_MIN % -1"    rem-min-neg1 \
       "rem-min-neg1: the table says arithmetic"             7:arithmetic 8:- 9:overflow
# A domain check applied to the final value only: (INT64_MAX + 1) - 1 is
# INT64_MAX, which fits, and the expression must still fail.
mutate "a final-value-only check"   mid-over \
       "mid-over: the table says ok"                         7:ok 8:9223372036854775807 9:-
# A case naming an entry that is not in the fixture.
mutate "an entry that is not there" const-mix \
       "const_mix.rb: the table exercises"                   3:const_mixx

echo "== a contract binds every case to its definition =="
# One contract per distinct (source, entry, result).  Accepting it is the
# check: the boundary tool resolves the entry in the analysed AST and compares
# the contract's parameter names and arity against the definition's, so a case
# naming the wrong entry or the wrong arity fails here.
n_contract=0
awk -F'\t' '!/^#/ && NF == 9 {
  n = split($6, a, ",")
  print $2, $3, $5, n
}' "$FIX/cases.tsv" | sort -u > "$WORK/contracts.txt"
while read -r src entry rt arity; do
  n_contract=$((n_contract + 1))
  out="$WORK/$entry-$rt.contract"
  {
    echo "core-contract 1"
    echo "root src/$src"
    echo "entry $entry"
    echo "result $rt"
    echo "param a scalar i64"
    [ "$arity" -ge 2 ] && echo "param b scalar i64"
  } > "$out"
  if id=$("$BOUNDARY" "$out" --root "$FIX" --identity 2>"$WORK/$entry-$rt.err"); then
    echo "  pass $entry -> $rt: $id"
    pass=$((pass + 1))
  else
    echo "  FAIL $entry -> $rt was refused:"; sed 's/^/      /' "$WORK/$entry-$rt.err"
    fail=$((fail + 1))
  fi
done < "$WORK/contracts.txt"
[ "$n_contract" -gt 0 ] || die "no contracts were generated from the case table"

# The control for that lane: if the generated contract did not really have to
# agree with the definition, every line above would pass whatever it said.
sed 's/^param a scalar i64$/param z scalar i64/' "$WORK/add-i64.contract" > "$WORK/wrong-name.contract"
if "$BOUNDARY" "$WORK/wrong-name.contract" --root "$FIX" >/dev/null 2>"$WORK/wrong-name.err"; then
  echo "  FAIL a contract naming a parameter the definition does not have was accepted"
  fail=$((fail + 1))
elif grep -q ': parameter-name: ' "$WORK/wrong-name.err"; then
  echo "  pass a wrong parameter name is refused, so the lane above binds"
  pass=$((pass + 1))
else
  echo "  FAIL the wrong parameter name was refused for another reason:"
  sed 's/^/      /' "$WORK/wrong-name.err" | head -3
  fail=$((fail + 1))
fi

echo "== execution =="
# Every case lands in exactly one bucket and there is no third:
#
#   ok          the kernel builds, runs, returns SPINEL_CORE_OK and writes the
#               declared value;
#   arithmetic  the kernel builds, runs, returns SPINEL_CORE_ARITHMETIC and
#               leaves the result WORD UNTOUCHED;
#   refused     the kernel does not build, and the diagnostic names the
#               declared category.
#
# A case that does none of these fails. The count of executed cases is printed
# either way, so "nothing ran" cannot read as "everything passed".
n_cases=$(awk -F'\t' '!/^#/ && NF == 9' "$FIX/cases.tsv" | wc -l | tr -d ' ')
executed=0
if [ ! -x "$KERNEL" ]; then
  echo "  NOT RUN $n_cases of $n_cases case(s): no spinel-core-kernel at $KERNEL"
  if [ "${REQUIRE_EXECUTION:-1}" = 1 ]; then
    echo "  FAIL the execution lane did not run"
    fail=$((fail + 1))
  fi
else
  # One kernel per distinct (source, entry, result): the contract is the same
  # for every case over that triple, and building it once per case would
  # measure the compiler 48 times and the answers 48 times in the same number.
  built_ok=""
  while read -r src entry rt arity; do
    kdir="$WORK/k/$entry-$rt"
    mkdir -p "$kdir"
    {
      echo "core-contract 1"
      echo "root src/$src"
      echo "entry $entry"
      echo "result $rt"
      echo "param a scalar i64"
      [ "$arity" -ge 2 ] && echo "param b scalar i64"
    } > "$kdir/k.contract"
    set +e
    "$KERNEL" "$kdir/k.contract" --root "$FIX" -o "$kdir/k.o" --header "$kdir/k.h" \
      --clang "$CC_BIN" > "$kdir/build.out" 2> "$kdir/build.err"
    echo $? > "$kdir/build.rc"
    set -e
  done < "$WORK/contracts.txt"

  # The C harness. Written here rather than checked in, because its parameter
  # list and its result type come from the same two columns the contract does:
  # a checked-in harness would be a third place for the arity to be stated.
  harness() { # $1 kdir  $2 entry  $3 rt  $4 arity
    _rt=$3
    case "$_rt" in
      i64) _cty="int64_t";  _conv="lld"; _cast="(long long)";          _sentinel="-1234567890123";;
      i32) _cty="int32_t";  _conv="lld"; _cast="(long long)";          _sentinel="-1234567";;
      u32) _cty="uint32_t"; _conv="llu"; _cast="(unsigned long long)"; _sentinel="4242424242u";;
      *)   echo "harness: unknown result type $_rt" >&2; return 1;;
    esac
    if [ "$4" -ge 2 ]; then
      _call="spinel_core_$2(strtoll(argv[1], 0, 10), strtoll(argv[2], 0, 10), &r)"
    else
      _call="spinel_core_$2(strtoll(argv[1], 0, 10), &r)"
    fi
    cat > "$1/h.c" <<HEOF
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include "k.h"

/* The untouched-result check is HERE and not in the shell: "unchanged" is a
 * fact about the caller's storage before and after the call, and the shell
 * only ever sees what was printed. */
int main(int argc, char **argv) {
  if (argc != $(($4 + 1))) return 99;
  const $_cty sentinel = $_sentinel;
  $_cty r = sentinel;
  int32_t st = $_call;
  if (st != 0) {
    printf("%d %s\n", (int)st, r == sentinel ? "untouched" : "TOUCHED");
    return 0;
  }
  printf("%d %$_conv\n", (int)st, $_cast r);
  return 0;
}
HEOF
    "$CC_BIN" -std=c11 -Wall -Wextra -Werror -I"$1" "$1/h.c" "$1/k.o" -o "$1/h" 2>"$1/h.log"
  }

  while IFS='	' read -r id src entry op rt args status value reason; do
    case "$id" in \#*|"") continue ;; esac
    kdir="$WORK/k/$entry-$rt"
    rc=$(cat "$kdir/build.rc")

    if [ "$status" = refused ]; then
      if [ "$rc" -eq 0 ]; then
        echo "  FAIL $id: the kernel built; it must be refused"
        fail=$((fail + 1))
      elif grep -q ": $reason: " "$kdir/build.err"; then
        echo "  pass $id refused ($reason)"
        pass=$((pass + 1)); executed=$((executed + 1))
      else
        echo "  FAIL $id refused for another reason (wanted $reason):"
        sed 's/^/      /' "$kdir/build.err" | head -3
        fail=$((fail + 1))
      fi
      continue
    fi

    if [ "$rc" -ne 0 ]; then
      echo "  FAIL $id: the kernel did not build:"
      sed 's/^/      /' "$kdir/build.err" | head -4
      fail=$((fail + 1)); continue
    fi
    if [ ! -x "$kdir/h" ]; then
      n=$(echo "$args" | awk -F, '{print NF}')
      if ! harness "$kdir" "$entry" "$rt" "$n"; then
        echo "  FAIL $id: the harness did not compile:"
        sed 's/^/      /' "$kdir/h.log" | head -6
        fail=$((fail + 1)); continue
      fi
    fi
    out=$("$kdir/h" $(echo "$args" | tr ',' ' ')) || {
      echo "  FAIL $id: the harness exited non-zero"; fail=$((fail + 1)); continue; }
    got_st=${out%% *}; got_val=${out#* }
    executed=$((executed + 1))
    if [ "$status" = ok ]; then
      if [ "$got_st" != 0 ]; then
        echo "  FAIL $id: expected SPINEL_CORE_OK, got status $got_st"
        fail=$((fail + 1))
      elif [ "$got_val" != "$value" ]; then
        echo "  FAIL $id: expected $value, got $got_val"
        fail=$((fail + 1))
      else
        echo "  pass $id = $got_val"
        pass=$((pass + 1))
      fi
    else
      # The ABI's own numbers, spelled once here. A case declares its status by
      # NAME so that the table never carries a bare integer whose meaning has
      # to be looked up somewhere else.
      case "$status" in
        argument)   want_st=1 ;;
        arithmetic) want_st=2 ;;
        bounds)     want_st=3 ;;
        capacity)   want_st=4 ;;
        *) echo "  FAIL $id declares status '$status', which is not one of the ABI's"
           fail=$((fail + 1)); continue ;;
      esac
      if [ "$got_st" != "$want_st" ]; then
        echo "  FAIL $id: expected $status ($want_st), got status $got_st"
        fail=$((fail + 1))
      elif [ "$got_val" != untouched ]; then
        echo "  FAIL $id: failed with status $got_st but wrote the result word"
        fail=$((fail + 1))
      else
        echo "  pass $id is $status ($reason), result untouched"
        pass=$((pass + 1))
      fi
    fi
  done < "$FIX/cases.tsv"

  echo "== the entry checks what the caller supplied =="
  # ARGUMENT is for the caller's own defect, and the result pointer is what a
  # scalar boundary can see of that. Both cases are checked through the SAME
  # kernel that the ok cases run, with a positive control beside them so that a
  # wrapper returning ARGUMENT for everything could not read as a pass.
  #
  # The misaligned pointer is built by hand rather than by taking the address
  # of a packed field: the point is an address the caller could really pass,
  # and it must be checked before anything is written to it.
  adir="$WORK/k/add-i64"
  if [ ! -f "$adir/k.o" ]; then
    echo "  FAIL no add kernel to check the entry with"
    fail=$((fail + 1))
  else
    cat > "$WORK/entry.c" <<'EEOF'
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "k.h"

/* Eight bytes of guard on each side, so a write anywhere near the target shows
 * up as a changed byte rather than as a changed value. */
/* Aligned deliberately: `slab + 1` is only reliably misaligned if `slab`
 * itself is not. Without this the array's own alignment is the compiler's
 * choice and the control could test nothing. */
_Alignas(8) static unsigned char slab[32];

static int untouched(void) {
  for (unsigned i = 0; i < sizeof slab; ++i)
    if (slab[i] != 0xAB) return 0;
  return 1;
}

int main(void) {
  int64_t r = -1;
  int32_t st;

  st = spinel_core_add(1, 2, (int64_t *)0);
  printf("null %d\n", (int)st);

  memset(slab, 0xAB, sizeof slab);
  /* A deliberately odd address inside the slab. Going through void* is what
   * lets this compile under -Werror; the address is the point. */
  void *odd = (void *)(slab + 1);
  st = spinel_core_add(1, 2, (int64_t *)odd);
  printf("misaligned %d %s\n", (int)st, untouched() ? "untouched" : "TOUCHED");

  r = -1;
  st = spinel_core_add(1, 2, &r);
  printf("aligned %d %lld\n", (int)st, (long long)r);
  return 0;
}
EEOF
    if "$CC_BIN" -std=c11 -Wall -Wextra -Werror -I"$adir" "$WORK/entry.c" "$adir/k.o" \
         -o "$WORK/entry" 2>"$WORK/entry.log"; then
      set +e
      "$WORK/entry" > "$WORK/entry.out" 2>&1
      entry_rc=$?
      set -e
      if [ "$entry_rc" -ne 0 ]; then
        # A crash here is the interesting outcome, not something to swallow:
        # the whole point is that a bad pointer must be refused rather than
        # written through.
        echo "  FAIL the entry-check program exited $entry_rc:"
        sed 's/^/      /' "$WORK/entry.out" | head -4
        fail=$((fail + 1))
      fi
      check_entry() { # $1 label  $2 expected line
        if grep -qx "$2" "$WORK/entry.out"; then
          echo "  pass $1"
          pass=$((pass + 1))
        else
          echo "  FAIL $1: wanted \"$2\", got \"$(grep "^${2%% *} " "$WORK/entry.out")\""
          fail=$((fail + 1))
        fi
      }
      check_entry "a NULL result pointer is ARGUMENT" "null 1"
      check_entry "a misaligned result pointer is ARGUMENT, and nothing is written" \
                  "misaligned 1 untouched"
      check_entry "an aligned pointer still works (so the check is not blanket)" \
                  "aligned 0 3"
    else
      echo "  FAIL the entry-check program did not compile:"
      sed 's/^/      /' "$WORK/entry.log" | head -6
      fail=$((fail + 1))
    fi
  fi

  echo "== the objects are free-standing =="
  # Decision 0007 keeps version 1 at zero undefined symbols. -O2 is what the
  # shared emitter uses, so this is the object the production path produces and
  # not a debug build of it. A loop the optimiser turns into a memset or a
  # memcpy would show up here rather than at link time in someone else's
  # program.
  #
  # The object format decides how a C name appears in the symbol table: ELF
  # writes `spinel_core_add`, Mach-O writes `_spinel_core_add`. That prefix is
  # MEASURED here rather than guessed from the platform -- a compiler probe
  # with a known symbol name, read back through the same nm -- because a guess
  # that is wrong reads as "the object exports the wrong symbol" for every
  # object, which is what it did on macOS.
  NM="${NM:-nm}"
  command -v "$NM" >/dev/null 2>&1 || die "no nm at '$NM'"
  cat > "$WORK/symprobe.c" <<'PEOF'
int spinel_core_symbol_probe(void) { return 0; }
PEOF
  "$CC_BIN" -c "$WORK/symprobe.c" -o "$WORK/symprobe.o" 2>"$WORK/symprobe.log" \
    || die "cannot compile the symbol probe: $(head -2 "$WORK/symprobe.log")"
  # One parse for both nm flavours: the NAME is the last field and the TYPE
  # letter the one before it, which holds for `0000 T name` and for `     U name`
  # alike. No -u and no --defined-only: neither is available everywhere, and
  # asking for a flag nm does not have is the failure that hid behind 2>/dev/null.
  symbols() { # $1 object -> "<type> <name>" per line, non-zero if nm failed
    "$NM" "$1" > "$WORK/nm.out" 2> "$WORK/nm.err" || return 1
    [ -s "$WORK/nm.out" ] || return 2
    awk 'NF >= 2 { print $(NF-1), $NF }' "$WORK/nm.out"
  }
  if ! probe=$(symbols "$WORK/symprobe.o"); then
    die "nm could not read the symbol probe: $(head -2 "$WORK/nm.err")"
  fi
  probe_name=$(echo "$probe" | awk '$2 ~ /spinel_core_symbol_probe$/ { print $2; exit }')
  [ -n "$probe_name" ] || die "nm did not report spinel_core_symbol_probe in the probe object"
  SYM_PREFIX=${probe_name%spinel_core_symbol_probe}
  echo "  pass this object format writes a C symbol as '${SYM_PREFIX}name' (measured)"
  pass=$((pass + 1))

  # The verdict, in one place, so the controls below exercise the SAME code
  # the kernels are judged by. Prints "clean" or the reason; non-zero on any
  # defect, including an nm that could not read the file.
  inspect_object() { # $1 object  $2 entry name
    if ! _table=$(symbols "$1"); then
      echo "nm could not read it: $(head -2 "$WORK/nm.err")"
      return 1
    fi
    _undef=$(echo "$_table" | awk '$1 == "U" { print $2 }' | tr '\n' ' ')
    _exported=$(echo "$_table" | awk '$1 != "U" && $1 ~ /^[A-Z]$/ { print $2 }' | tr '\n' ' ')
    if [ -n "$_undef" ]; then
      echo "undefined symbol(s): $_undef"
      return 1
    fi
    if [ "$_exported" != "${SYM_PREFIX}spinel_core_$2 " ]; then
      echo "exports [$_exported], not [${SYM_PREFIX}spinel_core_$2 ]"
      return 1
    fi
    echo clean
  }

  # Two controls, so a lane that accepted everything could not read as a pass.
  cat > "$WORK/ctl_undef.c" <<'PEOF'
extern int spinel_core_missing_callee(int);
int spinel_core_ctlundef(int x) { return spinel_core_missing_callee(x); }
PEOF
  cat > "$WORK/ctl_name.c" <<'PEOF'
int spinel_core_somethingelse(int x) { return x; }
PEOF
  for ctl in ctl_undef ctl_name; do
    "$CC_BIN" -O2 -c "$WORK/$ctl.c" -o "$WORK/$ctl.o" 2>"$WORK/$ctl.log" \
      || die "cannot compile the $ctl control: $(head -2 "$WORK/$ctl.log")"
  done
  if why=$(inspect_object "$WORK/ctl_undef.o" ctlundef); then
    echo "  FAIL an object with an undefined symbol was accepted"
    fail=$((fail + 1))
  else
    echo "  pass an undefined symbol is caught ($why)"
    pass=$((pass + 1))
  fi
  if why=$(inspect_object "$WORK/ctl_name.o" ctlname); then
    echo "  FAIL an object exporting the wrong symbol was accepted"
    fail=$((fail + 1))
  else
    echo "  pass a wrong exported symbol is caught ($why)"
    pass=$((pass + 1))
  fi

  n_obj=0
  obj_bad=0
  for kdir in "$WORK"/k/*/; do
    [ -f "$kdir/k.o" ] || continue
    n_obj=$((n_obj + 1))
    entry=$(sed -n 's/^entry //p' "$kdir/k.contract")
    if why=$(inspect_object "$kdir/k.o" "$entry"); then
      pass=$((pass + 1))
    else
      echo "  FAIL $entry: $why"
      fail=$((fail + 1)); obj_bad=$((obj_bad + 1))
    fi
  done
  if [ "$n_obj" -eq 0 ]; then
    echo "  FAIL no objects were inspected"
    fail=$((fail + 1))
  elif [ "$obj_bad" -ne 0 ]; then
    # Said explicitly, because the summary used to be printed unconditionally
    # and read as a pass while individual objects above had failed.
    echo "  $((n_obj - obj_bad)) of $n_obj object(s) are clean; $obj_bad are not"
  else
    echo "  pass all $n_obj object(s): no undefined symbols, one exported symbol each"
  fi

  if [ "$executed" -ne "$n_cases" ]; then
    echo "  FAIL only $executed of $n_cases case(s) reached a bucket"
    fail=$((fail + 1))
  else
    echo "  pass all $n_cases case(s) landed in a declared bucket"
    pass=$((pass + 1))
  fi
fi

echo "== core_fail is one spelling, and the rest are refused =="
# Decision 0007: the application-requested failure is `core_fail(:capacity)`,
# recognised only in this closure, and a conflicting user definition or any
# other argument is rejected. The internal categories a compiler-generated
# failure uses are a different matter: they overlap, and an application asking
# for one of the others would be naming a failure only the compiler can
# establish.
#
# Each refusal declares the diagnostic it must carry, so a refusal for the
# wrong reason fails here rather than passing again once the real defect is
# fixed.
# Each refusal ships its own contract beside it, so an arity or a parameter
# name is stated once and in the fixture rather than assembled here.
refuse_case() { # $1 fixture stem  $2 expected diagnostic category
  set +e
  "$KERNEL" "$FIX/refuse/$1.contract" --root "$FIX" -o "$WORK/$1.o" \
    --clang "$CC_BIN" > "$WORK/$1.out" 2>&1
  _rc=$?
  set -e
  if [ "$_rc" -eq 0 ]; then
    echo "  FAIL $1 built; it must be refused"
    fail=$((fail + 1))
  elif grep -q ": $2: " "$WORK/$1.out"; then
    echo "  pass $1 is refused ($2)"
    pass=$((pass + 1))
  else
    echo "  FAIL $1 refused for another reason (wanted $2):"
    sed 's/^/      /' "$WORK/$1.out" | head -3
    fail=$((fail + 1))
  fi
}

refuse_case core_fail_other_category unsupported-status
refuse_case core_fail_ok             unsupported-status
refuse_case core_fail_dynamic        unsupported-node
refuse_case core_fail_two_args       arity-mismatch
refuse_case core_fail_user_def       conflicting-intrinsic

echo "== the declaration supplies entry facts, and every use is validated =="
# Decision 0007: "A declaration supplies entry facts; the checker must validate
# every use and reachable callee against them." Every fixture in src/ is
# caller-free -- no evidence call anywhere -- so the 56 cases above are already
# the positive evidence that the facts carry the closure.
#
# What is left to show is that the derivation VALIDATES rather than paints. A
# `poly` painted with `int` would admit all three of these.
# Each of these is a shape a derivation that painted rather than proved would
# let through, and four of them are the ones Mac's source review named.
refuse_case facts_bool_result     type-evidence
refuse_case facts_join_conflict   type-evidence
refuse_case facts_branch_order    type-evidence
refuse_case facts_callee_conflict type-evidence
# int, then bool, then int: the join must not revive the first type once the
# second has met it.
refuse_case facts_three_returns   type-evidence
# A mismatch carried backwards one variable per iteration, with every local
# reassigned an integer after the loop so that the final environment looks
# clean.
refuse_case facts_loop_delay      type-evidence
# Five helpers deep, so the bool has to travel back up the chain.
refuse_case facts_chain           type-evidence
# `||=` / `&&=` short-circuit, so they are a different statement from the
# operator-assignments the mode admits.
refuse_case op_assign_short_circuit unsupported-node

# And the other direction: a source that DOES have a caller is still accepted.
#
# Not "through the producer's own types" -- measured, and it is worth being
# exact. A contract always supplies facts on this route, so the derivation is
# the authority for every one of these checks whether an evidence call is there
# or not. The producer's types stay authoritative on the ordinary route and
# nowhere else. What this shows is only that an evidence call does not get in
# the way.
if "$KERNEL" "$FIX/refuse/facts_with_evidence.contract" --root "$FIX" \
     -o "$WORK/with-evidence.o" \
     --clang "$CC_BIN" > "$WORK/with-evidence.out" 2>&1; then
  echo "  pass a source with a caller is still accepted"
  pass=$((pass + 1))
else
  echo "  FAIL a source with a caller was refused:"
  sed 's/^/      /' "$WORK/with-evidence.out" | head -4
  fail=$((fail + 1))
fi

echo "== named literal scalar constants =="
# Decision 0007 task 2 admits literal scalar constants, and `a * 2 + 3` does
# not exercise that -- it has no name in it. A constant here is a single
# unconditional top-level assignment of an integer literal, resolved at compile
# time. The accepted side is two executed cases above (named-const and its
# overflow); these are the definitions that must NOT resolve.
refuse_case const_redefined   constant-redefinition
refuse_case const_dynamic     dynamic-constant
refuse_case const_conditional binding-environment
refuse_case const_unresolved  unresolved-constant
refuse_case const_in_body     unanalysable-root

echo "== the whole signed i64 domain, and nothing past it =="
# Decision 0007: the native CORE ABI retains the entire signed i64 domain and
# native entry values have no nil sentinel, so INT64_MIN is an ordinary value
# on this route. The accepted side is three executed cases above -- the
# constant, the literal, and one step past it.
#
# Measured, and the reason these two refusals exist: for a literal outside
# signed 64 bits the producer emits a SATURATED `value` beside the exact text
# in `bigval`, so `9223372036854775808` arrives as `value 9223372036854775807`
# and `-9223372036854775809` as `value -9223372036854775808`. Reading `value`
# alone would accept both, and the second would be INT64_MIN -- a legal value
# on this route, and the wrong one.
refuse_case const_bignum   integer-representation
refuse_case literal_bignum integer-representation

echo "== an unknown external call is refused by name =="
# `band` stopped being a control for this the moment the checked mode admitted
# `&`: it is accepted now, so it cannot be the negative evidence for an
# unsupported call. This is a receiverless call to a name nothing defines.
refuse_case unknown_call unresolved-call

echo "== a call cycle is refused, and the derivation still terminates =="
# Decision 0007 admits "only a closed, statically resolved call graph". The
# cycle is refused by the checker; the point of running it here is also that
# the fixpoint TERMINATES on one -- a derivation that chased the cycle would
# hang rather than fail, and a hang is not a refusal.
refuse_case cycle_self   recursive-call
refuse_case cycle_mutual recursive-call

echo '== a while has no value, which is not the same as never arriving =='
# `if b > 0 then (while ...) else 7 end`. A branch that RETURNS never reaches
# the join and so takes the other arm's type; a `while` does reach it, carrying
# nil, and nil is not in this subset. Calling both "non-fallthrough" let this
# take the 7 -- the lowering refused it afterwards, but the checker had already
# said it was an integer.
refuse_case facts_while_value type-evidence

echo "== the scalar slice admits decision 0015 addition and keeps its other refusals =="
# Decision 0015 gives ordinary scalar arithmetic an abort failure channel.
# The checked boundary still has its independent status-returning contract.
if [ ! -x "$CHECK" ]; then
  echo "  FAIL no spinel-core-check at $CHECK"
  fail=$((fail + 1))
else
  # The boundary fixture has no caller: supply one in a test copy so the
  # ordinary scalar checker has actual Integer type evidence for both inputs.
  cat "$FIX/src/add.rb" > "$WORK/scalar-add.rb"
  printf '\nadd(1, 2)\n' >> "$WORK/scalar-add.rb"
  if "$CHECK" "$WORK/scalar-add.rb" --method add > "$WORK/legacy-add.out" 2>&1 \
     && grep -q 'CHECKED[[:space:]]add[[:space:]]' "$WORK/legacy-add.out"; then
    echo "  pass the scalar slice admits addition under decision 0015"
    pass=$((pass + 1))
  else
    echo "  FAIL the scalar slice did not admit addition under decision 0015:"
    sed 's/^/      /' "$WORK/legacy-add.out" | head -3
    fail=$((fail + 1))
  fi
  # Upstream a07741ff1 no longer marks INT64_MIN as IntegerNode.bigval;
  # ecbe5eb also admits it as a scalar literal. This uncalled fixture still
  # has poly parameters, so it must fail type evidence rather than admission.
  # It remains distinct from a typed INT64_MIN return-value acceptance test.
  # Decision 0042 admits `&` (stage 1), `<<` (stage 2) and `**` (stage 3)
  # on this slice, so the uncalled band.rb, shl.rb and power.rb are refused
  # only for their poly parameters, as int64_min.rb is.
  for pair in "shl.rb:shl:type-evidence" \
              "band.rb:band:type-evidence" "power.rb:power:type-evidence" \
              "named_const.rb:named_const:runtime-state" \
              "int64_min.rb:int64_min:type-evidence"; do
    src=${pair%%:*}; rest=${pair#*:}; entry=${rest%%:*}; want=${rest#*:}
    set +e
    "$CHECK" "$FIX/src/$src" --method "$entry" > "$WORK/legacy-$entry.out" 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      echo "  FAIL the unchecked slice admitted $entry"
      fail=$((fail + 1))
    elif grep -q "$want" "$WORK/legacy-$entry.out" \
         && { { [ "$entry" != int64_min ] && [ "$entry" != band ] &&
                [ "$entry" != shl ] && [ "$entry" != power ]; } ||
              grep -q 'parameter a is poly' "$WORK/legacy-$entry.out"; }; then
      echo "  pass the unchecked slice still refuses $entry ($want)"
      pass=$((pass + 1))
    else
      echo "  FAIL the unchecked slice refused $entry for another reason (wanted $want):"
      sed 's/^/      /' "$WORK/legacy-$entry.out" | head -3
      fail=$((fail + 1))
    fi
  done
fi

echo "arithmetic: $((pass + fail)) checked, $pass pass, $fail fail" \
     "(the oracle lane is $oracle_n checks of its own), $executed/$n_cases executed"
[ "$fail" -eq 0 ] || exit 1
