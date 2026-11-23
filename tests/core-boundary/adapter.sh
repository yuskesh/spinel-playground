#!/bin/sh
#
# tests/core-boundary/adapter.sh — the Full adapter's operations for decision
# 0007 task 4, written BEFORE the adapter exists.
#
#   ADAPTER=<spinel-core-adapter> tests/core-boundary/adapter.sh
#
# Two lanes run today:
#
#   1. the operation table is well formed -- six fields, distinct ids, every
#      operation and every status one this file knows;
#   2. the contract the adapter will be generated FROM is still accepted by the
#      boundary tool, and its buffer shape is what the table assumes.
#
# One does not:
#
#   3. execution. There is no adapter yet, so no operation can run; that count
#      is printed rather than hidden, and REQUIRE_EXECUTION=1 turns an
#      unexecuted case into a failure.
#
# Nothing here allocates, invokes or releases anything. Until lane 3 executes,
# this file establishes what the operations must answer, not that anything
# answers them.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HERE="$ROOT/tests/core-boundary"
FIX="$HERE/fixtures/adapter"
BUFFIX="$HERE/fixtures/buffers"
BOUNDARY="${BOUNDARY:-$ROOT/tools/mlir/native/build/bin/spinel-core-boundary}"
ADAPTER="${ADAPTER:-$ROOT/tools/mlir/native/build/bin/spinel-core-adapter}"
. "${ROOT:-$root}/tools/test/source-stamp.sh"
source_stamp kernel "$ADAPTER"

die() { echo "adapter: $*" >&2; exit 1; }
[ -f "$FIX/operations.tsv" ] || die "no operation table at $FIX/operations.tsv"
[ -x "$BOUNDARY" ] || die "no spinel-core-boundary at $BOUNDARY (build it first)"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/core-adapter.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
pass=0; fail=0; unmeasured=0; checked=0
TAB=$(printf '\t')

OPS="allocate bind store load store_words load_words invoke release"
# `id`, `zero` and `value` are the answers of the operations that do not return
# a status: allocate gives an ID or zero, and load gives an encoded value or a
# negative status.
ANSWERS="ok argument arithmetic bounds capacity id zero value"

echo "== the operation table is well formed =="
rows=$(awk -F"$TAB" '!/^#/ && NF { print }' "$FIX/operations.tsv")
[ -n "$rows" ] || die "the operation table holds no cases"

n_rows=$(echo "$rows" | awk -F"$TAB" 'END { print NR }')
bad=$(echo "$rows" | awk -F"$TAB" 'NF != 6 { n++ } END { print n + 0 }')
if [ "$bad" -ne 0 ]; then
  echo "  FAIL $bad row(s) do not have six fields"; fail=$((fail + 1))
else
  echo "  pass $n_rows case(s), six fields each"; pass=$((pass + 1))
fi

dupes=$(echo "$rows" | cut -f1 | sort | uniq -d)
if [ -n "$dupes" ]; then
  echo "  FAIL duplicate case id(s): $(echo "$dupes" | tr '\n' ' ')"; fail=$((fail + 1))
else
  echo "  pass every case id is distinct"; pass=$((pass + 1))
fi

unknown=$(echo "$rows" | cut -f2 | sort -u | while read -r o; do
  echo "$OPS" | tr ' ' '\n' | grep -qx "$o" || echo "$o"
done)
if [ -n "$unknown" ]; then
  echo "  FAIL operation(s) this file does not know: $(echo "$unknown" | tr '\n' ' ')"
  fail=$((fail + 1))
else
  echo "  pass every operation named is one of the seven"; pass=$((pass + 1))
fi

unknown=$(echo "$rows" | cut -f5 | sort -u | while read -r a; do
  echo "$ANSWERS" | tr ' ' '\n' | grep -qx "$a" || echo "$a"
done)
if [ -n "$unknown" ]; then
  echo "  FAIL answer(s) outside the ABI: $(echo "$unknown" | tr '\n' ' ')"; fail=$((fail + 1))
else
  echo "  pass every answer named is one this ABI has"; pass=$((pass + 1))
fi

# Every one of the seven operations must appear. A table that silently dropped
# one would look complete and cover six.
missing=""
for o in $OPS; do
  echo "$rows" | cut -f2 | grep -qx "$o" || missing="$missing $o"
done
if [ -n "$missing" ]; then
  echo "  FAIL no case exercises:$missing"; fail=$((fail + 1))
else
  echo "  pass all seven operations have at least one case"; pass=$((pass + 1))
fi

echo "== the contract the adapter is generated from =="
# The adapter is generated per contract, so the contract has to be one the
# boundary tool still accepts and has to have the shape the table assumes: a
# u8 input buffer with its own count, and an i64 result.
if id=$("$BOUNDARY" "$BUFFIX/src/sum_u8.contract" --root "$BUFFIX" --identity 2>"$WORK/id.err"); then
  echo "  pass sum_u8: $id"; pass=$((pass + 1))
else
  echo "  FAIL sum_u8's contract was refused:"; sed 's/^/      /' "$WORK/id.err" | head -3
  fail=$((fail + 1))
fi
case "$id" in
  *"src:u8/in/count(n_src)"*) echo "  pass its buffer is the u8 input the table assumes"; pass=$((pass + 1)) ;;
  *) echo "  FAIL its identity is not the shape this table was written against"; fail=$((fail + 1)) ;;
esac

echo "== execution =="
# Every case builds its own situation in C and performs one operation. Each
# runs in a FRESH PROCESS, so no id carries between them: the registry never
# reuses one, and a case that expected a particular number would be asserting
# the order the suite happens to run in.
[ -x "$ADAPTER" ] || die "no spinel-core-adapter at $ADAPTER (build it first)"
KERNEL="${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}"
source_stamp kernel "$KERNEL"
CC_BIN="${CC:-${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/clang}"
[ -x "$KERNEL" ] || die "no spinel-core-kernel at $KERNEL"
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"

# Three contracts, because one cannot answer every case. sum_u8 has no mutable
# participant and a loop the registry's count bounds, so it can neither fail on
# bounds nor be poisoned; store_at has an `inout` buffer and a caller-supplied
# index; sum_i64 is the only shape where a result id equal to a participant id
# differs in nothing but the id.
# sum_i16 and store_i8 carry decision 0018's narrow elements through an
# adapter: a signed load, a registry element check, and a kernel store outside
# the element.
# merge_into is the only contract here with TWO `inout` buffers, which is the
# one shape where the same id can be handed to two written participants. It was
# in the fixtures and named by nothing: until this row, passing one id to two
# `inout` slots had never been executed through a generated adapter at all.
kernels="sum_u8 sum_i64 store_at store_at_i64 collision merge_into sum_i16 store_i8"
for k in $kernels; do
  "$KERNEL" "$BUFFIX/src/$k.contract" --root "$BUFFIX" -o "$WORK/$k.o" \
    --header "$WORK/spinel_core_$k.h" --clang "$CC_BIN" >"$WORK/$k.k" 2>&1 \
    || die "the $k kernel did not build: $(head -2 "$WORK/$k.k")"
  "$ADAPTER" "$BUFFIX/src/$k.contract" --root "$BUFFIX" --outdir "$WORK" \
    --core-header "spinel_core_$k.h" >"$WORK/$k.a" 2>&1 \
    || die "the $k adapter did not generate: $(head -2 "$WORK/$k.a")"
done

# -Werror on the GENERATED source as well as the harness: an adapter that only
# compiles with warnings disabled is not one a Full build would accept.
# Three builds of the same source. `limited` lowers the id budget so exhaustion
# is reachable; `ceiling` starts the counter near INT32_MAX so the refusal is
# tested where the arithmetic used to overflow rather than only where a small
# constant stops it.
for build in plain limited ceiling; do
  flags=""
  [ "$build" = limited ] && flags="-DSPINEL_CORE_ADAPTER_ID_LIMIT=3"
  [ "$build" = ceiling ] && flags="-DSPINEL_CORE_ADAPTER_ID_START=2147483646"
  if ! "$CC_BIN" -std=c11 -Wall -Wextra -Werror $flags -I"$WORK" \
       "$WORK/spinel_adapter_registry.c" "$WORK/spinel_adapter_sum_u8.c" \
       "$WORK/spinel_adapter_sum_i64.c" "$WORK/spinel_adapter_store_at.c" \
       "$WORK/spinel_adapter_store_at_i64.c" "$WORK/spinel_adapter_collision.c" \
       "$WORK/spinel_adapter_merge_into.c" "$WORK/spinel_adapter_sum_i16.c" \
       "$WORK/spinel_adapter_store_i8.c" \
       "$FIX/harness.c" "$WORK/sum_u8.o" "$WORK/sum_i64.o" "$WORK/store_at.o" \
       "$WORK/store_at_i64.o" "$WORK/collision.o" "$WORK/merge_into.o" \
       "$WORK/sum_i16.o" "$WORK/store_i8.o" \
       -o "$WORK/harness-$build" -lpthread 2>"$WORK/harness-$build.log"; then
    echo "  FAIL the $build harness did not compile:"
    sed 's/^/      /' "$WORK/harness-$build.log" | head -6
    fail=$((fail + 1))
  fi
done
[ -x "$WORK/harness-plain" ] || die "no harness to run the cases with"

n_cases=$n_rows
executed=0
notapplicable=0
while IFS="$TAB" read -r id op setup args answer expect; do
  bin="$WORK/harness-plain"
  # The exhaustion case is built with a LOWERED id limit, so it reaches the
  # same refusal the real budget would without issuing two billion ids. Same
  # code, a different constant.
  [ "$id" = alloc-exhausted ] && bin="$WORK/harness-limited"
  case "$id" in *-ceiling) bin="$WORK/harness-ceiling" ;; esac
  set +e
  out=$("$bin" "$id" 2>"$WORK/$id.err")
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "  FAIL $id: the harness exited $rc"
    sed 's/^/      /' "$WORK/$id.err" | head -3
    fail=$((fail + 1)); continue
  fi
  got=$(echo "$out" | cut -d' ' -f1)
  saw=$(echo "$out" | cut -d' ' -f2)
  if [ "$got" = "n/a" ]; then
    # Not faked and not counted as a pass: sum_u8's loop is bounded by the
    # count the registry supplies, so it cannot be made to fail on bounds, and
    # it has no mutable participant to poison. Those cases need a contract with
    # an `inout` buffer and a kernel that can fail.
    echo "  NOT RUN $id: this contract cannot produce that failure"
    notapplicable=$((notapplicable + 1)); continue
  fi
  executed=$((executed + 1))
  case "$answer" in
    ok) want=0 ;; argument) want=1 ;; arithmetic) want=2 ;;
    bounds) want=3 ;; capacity) want=4 ;;
    id|zero|value) want=$answer ;;
    *) echo "  FAIL $id declares answer '$answer'"; fail=$((fail + 1)); continue ;;
  esac
  if [ "$got" != "$want" ]; then
    echo "  FAIL $id: expected $answer ($want), got $got"
    fail=$((fail + 1)); continue
  fi
  # THE EFFECT, WHERE THE ROW STATES ONE EXACTLY. The harness has always
  # printed a second field and this driver has always ignored it: `untouched`
  # and `result-unchanged` were read by people and by nothing else, so a case
  # could answer ARGUMENT while writing whatever it liked. A row whose expect
  # column begins with `=` names the second field exactly and it is compared.
  # The rows that describe their effect in prose still do only that, and say so
  # by not beginning with `=`.
  case "$expect" in
    "="*)
      if [ "$saw" != "${expect#=}" ]; then
        echo "  FAIL $id: answered $answer but left '$saw', wanted '${expect#=}'"
        fail=$((fail + 1)); continue
      fi
      checked=$((checked + 1))
      ;;
  esac
  echo "  pass $id -> $answer${saw:+ ($saw)}"
  pass=$((pass + 1))
done <<EOF
$rows
EOF

if [ "$((executed + notapplicable))" -ne "$n_cases" ]; then
  echo "  FAIL only $executed of $n_cases case(s) reached a bucket"
  fail=$((fail + 1))
elif [ "$notapplicable" -ne 0 ]; then
  echo "  $executed of $n_cases executed; $notapplicable need a contract with a"
  echo "  mutable participant and a kernel that can fail"
  if [ "${REQUIRE_EXECUTION:-0}" = 1 ]; then
    echo "  FAIL REQUIRE_EXECUTION=1 and $notapplicable case(s) did not execute"
    fail=$((fail + 1))
  fi
else
  echo "  pass all $n_cases case(s) executed"
  pass=$((pass + 1))
fi
# How many cases had their EFFECT compared and not merely their status. Printed
# rather than pinned, because the number should rise as rows gain an `=`
# expectation; what is checked is that it is not zero, which is what it was
# before this existed.
echo "  $checked case(s) had the effect compared as well as the answer"
if [ "$checked" -eq 0 ]; then
  echo "  FAIL no case compared its effect; the expect column is decorative again"
  fail=$((fail + 1))
fi

echo "== serialisation, and what it does not promise =="
# Decision 0007: one C-side mutex serialises every registry and helper
# operation, including the whole CORE invocation and release. What that does
# and does not promise are different claims and the harness separates them: it
# establishes id uniqueness across threads and that a thread's own storage
# holds what that thread put there, and it DEMONSTRATES that a sequence of
# operations is not a transaction rather than asserting the opposite.
conc_build() { # $1 suffix  $2 extra flags
  "$CC_BIN" -std=c11 -Wall -Wextra -Werror -O1 $2 -I"$WORK" \
    "$WORK/spinel_adapter_registry.c" "$WORK/spinel_adapter_sum_u8.c" \
    "$FIX/concurrency.c" "$WORK/sum_u8.o" -o "$WORK/conc$1" -lpthread \
    2>"$WORK/conc$1.log"
}
conc_check() { # $1 suffix  $2 label
  set +e
  "$WORK/conc$1" > "$WORK/conc$1.out" 2>&1
  _rc=$?
  set -e
  if [ "$_rc" -ne 0 ]; then
    echo "  FAIL $2: the harness exited $_rc:"
    sed 's/^/      /' "$WORK/conc$1.out" | head -6
    fail=$((fail + 1)); return
  fi
  if ! grep -qx 'ids-unique 1' "$WORK/conc$1.out" ||
     ! grep -qx 'threads-kept-their-own 1' "$WORK/conc$1.out"; then
    echo "  FAIL $2: serialisation did not hold:"
    sed 's/^/      /' "$WORK/conc$1.out" | head -6
    fail=$((fail + 1)); return
  fi
  echo "  pass $2: ids unique across threads, each thread's storage its own"
  pass=$((pass + 1))
  if grep -qx 'sequence-is-not-a-transaction demonstrated' "$WORK/conc$1.out"; then
    echo "  pass $2: a sequence of operations is not a transaction, demonstrated"
    pass=$((pass + 1))
  else
    # Not a pass. A run that did not happen to catch the interleaving has not
    # shown the pair IS atomic; it has shown nothing, and recording it as a
    # success would be recording the opposite of what it means.
    echo "  NOT SHOWN $2: the non-atomic pair was not observed in this run"
    unmeasured=$((unmeasured + 1))
  fi
}
if conc_build "" ""; then
  conc_check "" "plain"
else
  echo "  FAIL the concurrency harness did not compile:"
  sed 's/^/      /' "$WORK/conc.log" | head -6
  fail=$((fail + 1))
fi
# ThreadSanitizer, if this toolchain has it. Probed by building AND running,
# like the other sanitisers, and an unavailable one is recorded rather than
# folded into a pass.
cat > "$WORK/tsanprobe.c" <<'PEOF'
#include <pthread.h>
static int x;
static void *w(void *a) { (void)a; x = 1; return 0; }
int main(void) {
  pthread_t t;
  if (pthread_create(&t, 0, w, 0) != 0) return 1;
  pthread_join(t, 0);
  return x - 1;
}
PEOF
if "$CC_BIN" -fsanitize=thread -O1 "$WORK/tsanprobe.c" -o "$WORK/tsanprobe" \
     2>"$WORK/tsanprobe.log" && "$WORK/tsanprobe" >/dev/null 2>&1; then
  if conc_build "-tsan" "-fsanitize=thread"; then
    set +e
    "$WORK/conc-tsan" > "$WORK/conc-tsan.out" 2>&1
    trc=$?
    set -e
    if grep -q 'ThreadSanitizer' "$WORK/conc-tsan.out"; then
      echo "  FAIL thread: ThreadSanitizer reported on the adapter:"
      sed 's/^/      /' "$WORK/conc-tsan.out" | head -8
      fail=$((fail + 1))
    elif [ "$trc" -ne 0 ]; then
      echo "  FAIL thread: the instrumented harness exited $trc"
      fail=$((fail + 1))
    else
      echo "  pass thread: no race reported over the whole harness"
      pass=$((pass + 1))
    fi
  else
    echo "  FAIL the instrumented concurrency harness did not compile:"
    sed 's/^/      /' "$WORK/conc-tsan.log" | head -6
    fail=$((fail + 1))
  fi
else
  echo "  NOT RUN thread sanitiser unavailable here, so no race evidence"
  unmeasured=$((unmeasured + 1))
fi

echo "== the generated Ruby module, compiled by the pinned compiler =="
# The Full side, and the only lane that uses the pin. It calls the GENERATED
# module rather than the raw ffi_func bindings, because the module is what a
# Full caller is given.
#
# No vendor change is needed for any of this, and the suite would notice if one
# crept in: the compiler here is the pinned binary in vendor/.
# The PINNED compiler, and only that one. Two places are tried because a git
# worktree does not carry the submodule's checkout: the worktree's own vendor
# directory, then the main checkout's, found through git rather than guessed.
# PATH is never consulted -- a `spinel` from somewhere else would make the word
# "pinned" mean nothing, and this lane exists to say the pin needs no change.
SPINEL="${SPINEL:-}"
if [ -z "$SPINEL" ]; then
  for candidate in "$ROOT/vendor/spinel/bin/spinel" \
                   "$(git -C "$ROOT" rev-parse --path-format=absolute \
                        --git-common-dir 2>/dev/null)/../vendor/spinel/bin/spinel"; do
    [ -x "$candidate" ] || continue
    SPINEL=$candidate
    break
  done
fi
if [ -z "$SPINEL" ] || [ ! -x "$SPINEL" ]; then
  echo "  NOT RUN no pinned compiler found. Looked in this checkout's"
  echo "          vendor/spinel/bin and the main checkout's; a worktree does"
  echo "          not carry the submodule. Set SPINEL=<pinned binary> to run"
  echo "          this lane -- and set it to the PIN, not to a spinel on PATH."
  unmeasured=$((unmeasured + 1))
else
  echo "  using the pinned compiler at $SPINEL"
  "$CC_BIN" -std=c11 -O2 -c -I"$WORK" "$WORK/spinel_adapter_registry.c" \
    -o "$WORK/reg.o" 2>"$WORK/reg.log" || die "the registry did not compile"
  "$CC_BIN" -std=c11 -O2 -c -I"$WORK" "$WORK/spinel_adapter_sum_u8.c" \
    -o "$WORK/ad.o" 2>"$WORK/ad.log" || die "the sum_u8 adapter did not compile"
  cp "$FIX/full_probe.rb" "$WORK/full_probe.rb"
  if "$SPINEL" "$WORK/full_probe.rb" -o "$WORK/full_probe" -I "$WORK" \
       --link "$WORK/ad.o" --link "$WORK/reg.o" --link "$WORK/sum_u8.o" \
       --link -lpthread >"$WORK/full.build" 2>&1; then
    set +e
    "$WORK/full_probe" > "$WORK/full.out" 2>&1
    frc=$?
    set -e
    if [ "$frc" -ne 0 ]; then
      echo "  FAIL the Full probe exited $frc:"
      sed 's/^/      /' "$WORK/full.out" | head -4
      fail=$((fail + 1))
    elif diff -u "$FIX/full_probe.expected" "$WORK/full.out" > "$WORK/full.diff"; then
      # Byte for byte against a checked-in expectation, not a grep: every line
      # is a value the decision names, and an extra or missing one matters.
      echo "  pass the generated module answers exactly as declared"
      pass=$((pass + 1))
    else
      echo "  FAIL the Full probe printed something else:"
      sed 's/^/      /' "$WORK/full.diff" | head -12
      fail=$((fail + 1))
    fi
  else
    echo "  FAIL the pinned compiler refused the Full probe:"
    sed 's/^/      /' "$WORK/full.build" | head -6
    fail=$((fail + 1))
  fi
fi

echo "== packaging identity =="
# A contract produces four generated files and an object. A consumer compiles
# against one and links another, and once they are separate files nothing in
# them says which contract they came from. The manifest says it, and verifying
# it is what makes a swap a refusal instead of a link that silently succeeds.
PACKAGE="${PACKAGE:-$ROOT/tools/mlir/native/build/bin/spinel-core-package}"
if [ ! -x "$PACKAGE" ]; then
  echo "  FAIL no spinel-core-package at $PACKAGE"
  fail=$((fail + 1))
else
  pkg="$WORK/pkg"
  mkdir -p "$pkg"
  cp "$WORK/spinel_core_sum_u8.h" "$WORK/sum_u8.o" "$WORK/spinel_adapter_sum_u8.h" \
     "$WORK/spinel_adapter_sum_u8.c" "$WORK/spinel_adapter_registry.h" \
     "$WORK/spinel_adapter_registry.c" "$WORK/core_sum_u8.rb" "$pkg/"
  if "$PACKAGE" write "$BUFFIX/src/sum_u8.contract" --root "$BUFFIX" --dir "$pkg" \
       -o "$pkg/package.manifest" >"$WORK/pkg.write" 2>&1 &&
     "$PACKAGE" verify "$pkg/package.manifest" >"$WORK/pkg.verify" 2>&1; then
    echo "  pass a freshly written package verifies"
    pass=$((pass + 1))
  else
    echo "  FAIL a freshly written package did not verify:"
    sed 's/^/      /' "$WORK/pkg.write" "$WORK/pkg.verify" | head -6
    fail=$((fail + 1))
  fi

  refuse_pkg() { # $1 label  $2 expected category
    set +e
    "$PACKAGE" verify "$pkg/package.manifest" >"$WORK/pkg.$2" 2>&1
    _rc=$?
    set -e
    if [ "$_rc" -eq 0 ]; then
      echo "  FAIL $1 was accepted"
      fail=$((fail + 1))
    elif grep -q "$2" "$WORK/pkg.$2"; then
      echo "  pass $1 is refused ($2)"
      pass=$((pass + 1))
    else
      echo "  FAIL $1 was refused for another reason (wanted $2):"
      sed 's/^/      /' "$WORK/pkg.$2" | head -3
      fail=$((fail + 1))
    fi
  }

  # An edited header.
  cp "$pkg/spinel_core_sum_u8.h" "$WORK/hdr.keep"
  sed 's/sum_u8 -> i64/sum_u8 -> tampered/' "$WORK/hdr.keep" > "$pkg/spinel_core_sum_u8.h"
  refuse_pkg "an edited header" digest-mismatch
  cp "$WORK/hdr.keep" "$pkg/spinel_core_sum_u8.h"

  # The ADAPTER object presented as the CORE object. The decision asks for
  # exactly this: the adapter carries malloc and pthread and the CORE object
  # carries nothing, and packaging must not let one stand in for the other.
  "$CC_BIN" -std=c11 -O2 -c -I"$WORK" "$WORK/spinel_adapter_sum_u8.c" \
    -o "$WORK/swap.o" 2>/dev/null
  cp "$pkg/sum_u8.o" "$WORK/obj.keep"
  cp "$WORK/swap.o" "$pkg/sum_u8.o"
  refuse_pkg "the adapter object in the CORE object's place" digest-mismatch
  cp "$WORK/obj.keep" "$pkg/sum_u8.o"

  # A manifest written from a DIFFERENT contract over the same artefacts: every
  # digest matches, and the files still say whose they are. This is the case
  # the identity line exists for -- packaging with the wrong contract, rather
  # than editing a file.
  mkdir -p "$WORK/altroot/src"
  cp "$BUFFIX/src/sum_u8.rb" "$WORK/altroot/src/"
  sed 's/^result i64$/result i32/' "$BUFFIX/src/sum_u8.contract" > "$WORK/altroot/alt.contract"
  if "$PACKAGE" write "$WORK/altroot/alt.contract" --root "$WORK/altroot" --dir "$pkg" \
       -o "$pkg/alt.manifest" >"$WORK/pkg.alt" 2>&1; then
    set +e
    "$PACKAGE" verify "$pkg/alt.manifest" >"$WORK/pkg.identity" 2>&1
    arc=$?
    set -e
    if [ "$arc" -eq 0 ]; then
      echo "  FAIL a manifest from another contract verified against these files"
      fail=$((fail + 1))
    elif grep -q 'identity-mismatch' "$WORK/pkg.identity"; then
      echo "  pass a manifest from another contract is refused (identity-mismatch)"
      pass=$((pass + 1))
    else
      echo "  FAIL it was refused for another reason:"
      sed 's/^/      /' "$WORK/pkg.identity" | head -3
      fail=$((fail + 1))
    fi
  else
    echo "  FAIL could not write the second manifest:"
    sed 's/^/      /' "$WORK/pkg.alt" | head -3
    fail=$((fail + 1))
  fi

  # A manifest naming nothing. Verifying it establishes nothing, so it is a
  # refusal rather than a vacuous success.
  printf 'core-package\t1\nidentity\tx\n' > "$pkg/empty.manifest"
  set +e
  "$PACKAGE" verify "$pkg/empty.manifest" >"$WORK/pkg.empty" 2>&1
  erc=$?
  set -e
  if [ "$erc" -eq 0 ]; then
    echo "  FAIL a manifest naming no artefacts verified"
    fail=$((fail + 1))
  else
    echo "  pass a manifest naming no artefacts is refused"
    pass=$((pass + 1))
  fi
fi

# REQUIRE_ALL asks for the evidence, not for a report saying where evidence is
# missing. Each `unmeasured` above is a sub-lane that produced none -- a thread
# sanitiser this toolchain does not have, a pinned compiler that is not in this
# checkout, an interleaving this run did not happen to catch -- and run.sh's
# own REQUIRE_ALL cannot see any of them, because the lane still prints a
# summary and exits 0. Measured: with SPINEL=/nonexistent and REQUIRE_ALL=1
# this lane came back "61 checked, 61 pass, 0 fail, 1 lane(s) unmeasured" and
# exit 0, which run.sh printed as ok.
#
# So the lane makes them its own refusal. The counts are NOT moved: nothing
# here failed a check, and a count that changed with the environment would stop
# being comparable between machines. What changes is the exit status.
require_all_fail=0
if [ "${REQUIRE_ALL:-0}" = 1 ] && [ "$unmeasured" -ne 0 ]; then
  echo "  REQUIRE_ALL is set and $unmeasured sub-lane(s) produced no evidence. Each is"
  echo "  named above, with what it wanted. The counts below are unchanged: this is a"
  echo "  refusal of the run, not a failed check."
  require_all_fail=1
fi

echo "adapter: $((pass + fail)) checked, $pass pass, $fail fail," \
     "$executed/$n_cases executed, $notapplicable not applicable here," \
     "$unmeasured lane(s) unmeasured"
[ "$fail" -eq 0 ] || exit 1
[ "$require_all_fail" -eq 0 ] || exit 1
