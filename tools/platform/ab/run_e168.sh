#!/bin/sh
# run_e168.sh — the single canonical entry of E168 (byte equality of the Ruby spinel-capcheck).
#
# The skeleton follows the earlier runners: RepoGuard watches writes to the repository,
# INJECT is a closed set, and a summary line is printed. **The suite is always started**.
#
# It lives in `tools/platform/ab` because this lane has nothing to do with mlir
# (the design's section 4).
set -u
# An oracle (tests/ORACLES.tsv): it runs only on the owner's instruction.
"$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)/tools/oracle/gate" tools/platform/ab/run_e168.sh whole || exit 0

PROG=e168
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
TAB="$HERE/e168_cases.tsv"
IDT="$HERE/e168_identity.tsv"

fails=0
red() { echo "FAIL: $PROG — $*" >&2; fails=$((fails + 1)); }
fatal() { echo "$PROG: fatal: $*" >&2; exit 2; }

# ---- E173 (P014 Phase 1): golden fixture -----------------------------------
# `--record` **runs the frozen Python and writes the golden** (then, in the same run,
# runs it once more to count drift). The default compares with the golden; from the second checkpoint on
# it does not start python3.
MODE=golden
REC_OS=
[ "${1:-}" = "--record" ] && { MODE=record; shift; }
# `--os darwin` — **records into the overlay** (only the files that differ by OS, into golden.darwin/).
# So the path can be tried without the real machine, the suite looks at SPINEL_GOLDEN_OS.
if [ "${1:-}" = "--os" ] && [ -n "${2:-}" ]; then REC_OS=$2; shift 2; fi
GOLDEN_DIR="$REPO/docs/experiments/results/E168/golden"

INJECT_TOKENS="none suite-skip ruby-absent class-drift pin-drift case-skip golden-absent golden-drift"
INJECT="${SPINEL_E168_INJECT:-none}"
# The real number of positive controls (excluding `none`). The summary (`evidence=`) and the diagnostic (`controls=`)
# **come from the same variable** — the same number is not written in 2 places.
EVIDENCE_N=$(set -- $INJECT_TOKENS; echo $(($# - 1)))
_known=0
for t in $INJECT_TOKENS; do [ "$t" = "$INJECT" ] && _known=1; done
[ "$_known" -eq 1 ] || fatal "unknown SPINEL_E168_INJECT='$INJECT' (closed set: $INJECT_TOKENS)"

[ -r "$TAB" ] || fatal "e168_cases.tsv is missing ($TAB)"
[ -r "$IDT" ] || fatal "e168_identity.tsv is missing ($IDT)"

TMP=$(mktemp -d) || fatal "mktemp"
trap 'rm -rf "$TMP"' EXIT INT TERM
TAB_C=$(printf '\t')

# ---- write guard ------------------------------------------------------------
GUARD_RB="$REPO/tools/mlir/native/ab/inject_pool.rb"
[ -r "$GUARD_RB" ] || fatal "the write guard ($GUARD_RB) is missing"
guard_snapshot() {
  ruby -r "$GUARD_RB" -e '
    g = InjectPool::RepoGuard.new(ARGV[0])
    snap = g.snapshot
    File.open(ARGV[1], "w") { |f| snap.sort.each { |k, v| f.puts("#{k}\t#{v}") } }
    warn "entries=#{snap.size}"
  ' "$REPO" "$1" 2>"$1.n"
  sed -n 's/^entries=//p' "$1.n"
}
GUARD_BEFORE=$(guard_snapshot "$TMP/guard.before")
[ -n "$GUARD_BEFORE" ] && [ "$GUARD_BEFORE" -gt 1000 ] ||
  fatal "the write guard scans too few entries ('$GUARD_BEFORE')"

# ---- counts matched exactly as literals ------------------------------------
DECL_N=$(awk -F"$TAB_C" 'NR>1 && NF>=5 {n++} END {print n+0}' "$TAB")
CHECK_N=$(awk -F"$TAB_C" 'NR>1 && $2=="check" {n++} END {print n+0}' "$TAB")
RC0_N=$(awk -F"$TAB_C" 'NR>1 && $4=="0" {n++} END {print n+0}' "$TAB")
RC1_N=$(awk -F"$TAB_C" 'NR>1 && $4=="1" {n++} END {print n+0}' "$TAB")
RC2_N=$(awk -F"$TAB_C" 'NR>1 && $4=="2" {n++} END {print n+0}' "$TAB")
PIN_N=$(awk -F"$TAB_C" 'NR>1 && NF==2 {n++} END {print n+0}' "$IDT")
[ "$DECL_N" -eq 46 ] || red "the number of cases is not 46 ($DECL_N)"
[ "$CHECK_N" -eq 30 ] || red "the number of check rows is not 30 ($CHECK_N)"
[ "$RC0_N" -eq 15 ] || red "the number of rc 0 rows is not 15 ($RC0_N)"
[ "$RC1_N" -eq 20 ] || red "the number of rc 1 rows is not 20 ($RC1_N)"
[ "$RC2_N" -eq 11 ] || red "the number of rc 2 rows is not 11 ($RC2_N)"
# 5 -> 4 (the SHA pin of the frozen `spinel_platform.py` was retired).
# **This number is also in the suite's SHAPE["pins"]**.
[ "$PIN_N" -eq 4 ] || red "the number of identity pins is not 4 ($PIN_N)"

SUITE_ENV="SPINEL_E168_MODE=$MODE ${REC_OS:+SPINEL_GOLDEN_OS=$REC_OS} LC_ALL=C"
case "$INJECT" in
  ruby-absent)
    echo "  INJECT ruby-absent: point the Ruby CLI at a missing path"
    SUITE_ENV="$SUITE_ENV SPINEL_E168_RUBY_CLI=$TMP/no-such-capcheck" ;;
  class-drift)
    echo "  INJECT class-drift: invert the expected rc of 1 accepted row (e090_g_s1_accept)"
    SUITE_ENV="$SUITE_ENV SPINEL_E168_CLASS_DRIFT=1" ;;
  pin-drift)
    echo "  INJECT pin-drift: shift the pin of menus.yaml by 1 character"
    SUITE_ENV="$SUITE_ENV SPINEL_E168_PIN_DRIFT=1" ;;
  case-skip)
    echo "  INJECT case-skip: drop 1 row from the corpus to try to get green"
    SUITE_ENV="$SUITE_ENV SPINEL_E168_CASE_SKIP=e090_r1_tier_core" ;;
  golden-absent)
    echo "  INJECT golden-absent: point the golden fixture at a missing dir (a skip does not make it green)"
    SUITE_ENV="$SUITE_ENV SPINEL_E168_GOLDEN=$TMP/no-such-golden" ;;
  golden-drift)
    echo "  INJECT golden-drift: lengthen the product's output by 1 byte so it differs from the golden"
    SUITE_ENV="$SUITE_ENV SPINEL_E168_GOLDEN_DRIFT=1" ;;
esac

if [ "$INJECT" = suite-skip ]; then
  echo "  INJECT suite-skip: remove the suite run"
  SUITE_RC=0
  : > "$TMP/suite.out"
else
  # shellcheck disable=SC2086
  env $SUITE_ENV ruby "$HERE/test_e168.rb" > "$TMP/suite.out" 2>&1
  SUITE_RC=$?
fi
SUITE_LINE=$(grep -a -oE '[0-9]+ runs, [0-9]+ assertions, [0-9]+ failures, [0-9]+ errors' "$TMP/suite.out" | head -1)
[ -n "$SUITE_LINE" ] || red "the suite was not run — an isolated suite is not called evidence"
[ "$SUITE_RC" -eq 0 ] || red "the suite is red (rc=$SUITE_RC): ${SUITE_LINE:-no output}"
if [ "$SUITE_RC" -eq 0 ] && [ -n "$SUITE_LINE" ]; then
  _r=$(printf '%s\n' "$SUITE_LINE" | sed -n 's/^\([0-9]*\) runs.*/\1/p')
  # 8 -> 7. `test_frozen_mlirgen_still_imports_spinel_platform`
  # was retired together with its subject (the frozen `spinel-mlirgen.py` and `spinel_platform.py` are
  # both deleted). **This pin caught the leftover** — measured, it went red with
  # "green, but the tests are not 8 (7)". A change that lowers a count
  # writes its reason.
  [ "$_r" = "7" ] || red "green, but the suite does not have 7 tests ($_r) — deleting tests does not make it green"
fi
echo "$PROG:   suite: ${SUITE_LINE:-(not started)}"
[ "$SUITE_RC" -eq 0 ] || cat "$TMP/suite.out" >&2

GUARD_AFTER=$(guard_snapshot "$TMP/guard.after")
if diff -q "$TMP/guard.before" "$TMP/guard.after" >/dev/null 2>&1; then
  echo "$PROG:   repo-write guard: before=$GUARD_BEFORE after=$GUARD_AFTER diff=0"
elif [ "$MODE" = record ]; then
  # `--record`'s **job is to write fixtures into the repository**, so the guard's difference
  # is not a failure. It only prints how many entries moved.
  echo "$PROG:   repo-write guard: before=$GUARD_BEFORE after=$GUARD_AFTER (--record, so a difference is expected)"
else
  red "wrote to the repository"
  diff "$TMP/guard.before" "$TMP/guard.after" | head -20 >&2
fi
echo "$PROG:   evidence controls=$EVIDENCE_N active=$INJECT"

GOLDEN_N=$(ls -1 "$GOLDEN_DIR" 2>/dev/null | grep -c -v '\.tsv$')
# At the first checkpoint the suite counts "golden == the frozen tool's raw output" (mode=both/record).
# Once the default is golden only (second checkpoint), drift becomes `-`.
DRIFT=0
[ "$MODE" = golden ] && DRIFT=-

if [ "$fails" -eq 0 ]; then
  echo "$PROG: PASS cases=$DECL_N identical=$DECL_N check=$CHECK_N rc0=$RC0_N rc1=$RC1_N rc2=$RC2_N pins=$PIN_N evidence=$EVIDENCE_N golden=$GOLDEN_N drift=$DRIFT"
  exit 0
fi
echo "$PROG: FAIL ($fails)"
exit 1
