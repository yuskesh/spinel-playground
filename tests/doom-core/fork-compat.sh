#!/bin/sh
#
# tests/doom-core/fork-compat.sh — decision 0008 task 1's fork measurement.
#
# Which of the predecessor fork's defects does the compiler THIS repository
# pins still have? Every row of tests/doom-core/fork/ledger.tsv is accounted
# for, and the kinds of row are kept apart because they are different kinds of
# claim:
#
#   a row with a fixture   the reproducer imported from the fork is compiled
#                          and run here, several times, and the result must
#                          equal the `run_status` the ledger pins:
#                          `reproduced` (the defect is still here) or
#                          `not-reproduced` (this pin has it fixed).
#   a row with no fixture   `not-run` or `not-applicable`. Its reason is
#                          printed. It is counted as deferred and is NEVER
#                          counted as a passing execution.
#   an instrument or patch  source provenance, printed under its own heading,
#                          never mixed with execution.
#
# The script FAILS when it cannot make the measurement -- a fixture missing or
# not matching the ledger's digest, a row it did not execute -- and when a
# measurement disagrees with the pinned `run_status`, which is how the ledger
# is kept from going stale.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LEDGER="$ROOT/tests/doom-core/fork/ledger.tsv"
FIX="$ROOT/tests/doom-core/fork/fixtures"
SPINEL="${SPINEL:-$ROOT/vendor/spinel/bin/spinel}"
REPS=${FORK_REPS:-5}

die() { echo "fork-compat: $*" >&2; exit 1; }
[ -f "$LEDGER" ] || die "no ledger at $LEDGER"
[ -x "$SPINEL" ] || die "no compiler at $SPINEL (build it: see docs/building.md)"

# THE TOOLCHAIN IS NAMED, NOT INHERITED. An unset LLVM_PREFIX is how a Stage 1
# run silently fell back to a different compiler and produced a result nobody
# could reproduce. `vendor/spinel/src/main.c` at the pin hardcodes the command
# name `cc` and reads no CC from the environment; only --cc= overrides it, so
# this passes it explicitly.
if [ -n "${CLANG:-}" ]; then
  CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then
  CC_BIN=$LLVM_PREFIX/bin/clang
else
  die "set LLVM_PREFIX (or CLANG) to the official LLVM 23.1.1 you intend to measure; this script refuses to guess"
fi
[ -x "$CC_BIN" ] || die "no C compiler at $CC_BIN"

TAB=$(printf "\\t")
W=$(mktemp -d "${TMPDIR:-/tmp}/doom-core-fork.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM

echo "fork-compat: compiler $SPINEL"
"$SPINEL" --version 2>&1 | sed 's/^/fork-compat:   /'
echo "fork-compat: C toolchain $CC_BIN"
"$CC_BIN" --version 2>&1 | head -1 | sed 's/^/fork-compat:   /'
echo "fork-compat: each row with a fixture runs $REPS time(s); any deviation is the defect"

rows=0; executed=0; agreed=0; disagreed=0; deferred=0; sourced=0; errors=0
grep -v '^#' "$LEDGER" | grep -v '^[[:space:]]*$' > "$W/rows.tsv"
total=$(grep -c '' "$W/rows.tsv")

echo
echo "== source provenance (not execution) =="
while IFS="$TAB" read -r id commit fixture domain sstat rstat decision reason subject upstream sha stress; do
  case "$domain" in instrumentation) ;; *) [ "${id#P}" != "$id" ] || continue ;; esac
  rows=$((rows + 1)); sourced=$((sourced + 1))
  printf '  %-8s %-16s %s\n' "$id" "$domain/$decision" "$subject"
  printf '           %s\n' "$reason"
done < "$W/rows.tsv"

echo
echo "== not executed (no reproducer; not a pass) =="
while IFS="$TAB" read -r id commit fixture domain sstat rstat decision reason subject upstream sha stress; do
  case "$domain" in instrumentation) continue ;; esac
  [ "${id#P}" = "$id" ] || continue
  [ "$fixture" = "-" ] || continue
  rows=$((rows + 1)); deferred=$((deferred + 1))
  case "$rstat" in
    not-run|not-applicable) ;;
    *) printf '  %-8s ERROR    run_status %s with no fixture to produce it\n' "$id" "$rstat"
       errors=$((errors + 1)); continue ;;
  esac
  [ -n "$reason" ] || { printf '  %-8s ERROR    %s with no reason\n' "$id" "$rstat"; errors=$((errors + 1)); continue; }
  printf '  %-8s %-16s %s\n' "$id" "$rstat/$decision" "$subject"
  printf '           %s\n' "$reason"
done < "$W/rows.tsv"

echo
echo "== measured against the pin =="
while IFS="$TAB" read -r id commit fixture domain sstat rstat decision reason subject upstream sha stress; do
  case "$domain" in instrumentation) continue ;; esac
  [ "${id#P}" = "$id" ] || continue
  [ "$fixture" != "-" ] || continue
  rows=$((rows + 1))
  src="$FIX/$fixture"
  exp="$FIX/$fixture.expected"
  if [ ! -f "$src" ] || [ ! -f "$exp" ]; then
    printf '  %-8s ERROR    the ledger names %s, which is not in the fixtures\n' "$id" "$fixture"
    errors=$((errors + 1)); continue
  fi
  # sha256sum is coreutils; macOS has shasum. Chosen by what exists, as
  # loop-reports.sh does.
  got_sha=$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$src"; else shasum -a 256 "$src"; fi | cut -d' ' -f1)
  if [ "$got_sha" != "$sha" ]; then
    printf '  %-8s ERROR    %s is sha256 %s, the ledger says %s\n' "$id" "$fixture" "$got_sha" "$sha"
    errors=$((errors + 1)); continue
  fi

  bin="$W/$id"
  if "$SPINEL" "$src" --cc="$CC_BIN" -o "$bin" > "$W/$id.build" 2>&1; then
    # ONE RUN IS NOT A MEASUREMENT FOR THESE. B2 is a rooting defect that fires
    # only when a collection lands inside the merge chain; the fork
    # characterised its own reproducers by repetition ("5/5", "10/10") for the
    # same reason. The verdict is `reproduced` if ANY repetition deviates.
    ok=0; worst=""
    i=1
    while [ "$i" -le "$REPS" ]; do
      if "$bin" > "$W/$id.out.$i" 2> "$W/$id.err"; then rc=0; else rc=$?; fi
      if [ "$rc" -eq 0 ] && cmp -s "$W/$id.out.$i" "$exp"; then
        ok=$((ok + 1))
      elif [ "$rc" -ne 0 ]; then
        worst="the program exited $rc"
      else
        [ -n "$worst" ] || worst="the output differs from the fork's expected bytes"
      fi
      i=$((i + 1))
    done
    if [ "$ok" -eq "$REPS" ]; then
      measured=not-reproduced
      detail="its expected bytes came back, $ok/$REPS runs"
    else
      measured=reproduced
      detail="$worst ($ok/$REPS runs agreed)"
    fi
  else
    measured=reproduced
    detail="it does not compile: $(tail -1 "$W/$id.build")"
  fi

  if [ "$stress" = "stress" ] && [ -x "$bin" ]; then
    # A ROOTING DEFECT MAY NOT SHOW AT THE DEFAULT THRESHOLD. Forcing a full
    # collection as often as the runtime allows is the condition the fork found
    # these under; reported on its own line so it is never read as the default
    # run, and it can only make the verdict worse, never better.
    sok=0
    i=1
    while [ "$i" -le "$REPS" ]; do
      if SPINEL_GC_FULL_INTERVAL=1 "$bin" > "$W/$id.stress.$i" 2>&1; then src_rc=0; else src_rc=$?; fi
      [ "$src_rc" -eq 0 ] && cmp -s "$W/$id.stress.$i" "$exp" && sok=$((sok + 1))
      i=$((i + 1))
    done
    if [ "$sok" -eq "$REPS" ]; then
      stressline="under SPINEL_GC_FULL_INTERVAL=1: same expected bytes, $sok/$REPS runs"
    else
      stressline="under SPINEL_GC_FULL_INTERVAL=1: DIFFERS ($sok/$REPS runs agreed)"
      measured=reproduced
    fi
  else
    stressline=""
  fi

  executed=$((executed + 1))
  if [ "$measured" = "$rstat" ]; then
    agreed=$((agreed + 1))
    printf '  %-8s %-16s %s\n' "$id" "$measured/$decision" "$subject"
  else
    disagreed=$((disagreed + 1)); errors=$((errors + 1))
    printf '  %-8s DISAGREES the ledger pins %s, this run measured %s\n' "$id" "$rstat" "$measured"
    printf '  %-8s %-16s %s\n' "" "$measured" "$subject"
  fi
  printf '           %s\n' "$detail"
  [ -z "$stressline" ] || printf '           %s\n' "$stressline"
  case "$rstat" in reproduced) [ -n "$reason" ] || { printf '           ERROR a reproduced row needs a reason\n'; errors=$((errors + 1)); } ;; esac
done < "$W/rows.tsv"

echo
echo "fork-compat: $rows of $total ledger row(s) accounted for"
echo "fork-compat: executed $executed (agreeing with the ledger $agreed, disagreeing $disagreed), not executed $deferred, source $sourced, errors $errors"
if [ "$rows" -ne "$total" ]; then
  echo "fork-compat: $((total - rows)) row(s) were not executed, which is not a pass" >&2
  exit 1
fi
[ "$errors" -eq 0 ] || exit 1
