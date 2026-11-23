#!/bin/sh
# run_e170.sh — the single canonical entry of E170 (byte equality of the raster lane's 3 tools).
#
# The skeleton follows the earlier runners: RepoGuard watches writes to the repository,
# INJECT is a closed set, and a summary line is printed. **The suite is always started**.
#
# What is compared is stdout / stderr / rc and the outputs (header / MLIR / TSV / blob).
# The suite also checks every time that `sp_job_table.h` does not move.
set -u
# An oracle (tests/ORACLES.tsv): it runs only on the owner's instruction.
"$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)/tools/oracle/gate" tools/raster/ab/run_e170.sh whole || exit 0

PROG=e170
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
TAB="$REPO/docs/experiments/results/E170/cases.tsv"
IDT="$REPO/docs/experiments/results/E170/identity.tsv"

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
GOLDEN_DIR="$REPO/docs/experiments/results/E170/golden"

INJECT_TOKENS="none suite-skip ruby-absent header-drift class-drift pin-drift case-skip golden-absent golden-drift"
INJECT="${SPINEL_E170_INJECT:-none}"
_known=0
for t in $INJECT_TOKENS; do [ "$t" = "$INJECT" ] && _known=1; done
[ "$_known" -eq 1 ] || fatal "unknown SPINEL_E170_INJECT='$INJECT' (closed set: $INJECT_TOKENS)"

[ -r "$TAB" ] || fatal "cases.tsv is missing ($TAB)"
[ -r "$IDT" ] || fatal "identity.tsv is missing ($IDT)"

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
DECL_N=$(awk -F"$TAB_C" 'NR>1 && NF>=6 {n++} END {print n+0}' "$TAB")
JT_N=$(awk -F"$TAB_C" 'NR>1 && $2=="jobtable" {n++} END {print n+0}' "$TAB")
RG_N=$(awk -F"$TAB_C" 'NR>1 && $2=="rastergen" {n++} END {print n+0}' "$TAB")
JC_N=$(awk -F"$TAB_C" 'NR>1 && $2=="jobcheck" {n++} END {print n+0}' "$TAB")
# The rows that pass `@OUT@` and **the rows that really leave outputs** differ (`jt_check_bad_header`
# only reads a missing header and writes nothing). Both are pinned.
OUT_N=$(awk -F"$TAB_C" 'NR>1 && $3 ~ /@OUT@/ {n++} END {print n+0}' "$TAB")
ART_N=$(awk -F"$TAB_C" 'NR>1 && $5!="-" {n++} END {print n+0}' "$TAB")
RC0_N=$(awk -F"$TAB_C" 'NR>1 && $4=="0" {n++} END {print n+0}' "$TAB")
RC1_N=$(awk -F"$TAB_C" 'NR>1 && $4=="1" {n++} END {print n+0}' "$TAB")
RC2_N=$(awk -F"$TAB_C" 'NR>1 && $4=="2" {n++} END {print n+0}' "$TAB")
PIN_N=$(awk -F"$TAB_C" 'NR>1 && NF==2 {n++} END {print n+0}' "$IDT")
[ "$DECL_N" -eq 51 ] || red "the number of cases is not 51 ($DECL_N)"
[ "$JT_N" -eq 19 ] || red "the number of jobtable rows is not 19 ($JT_N)"
[ "$RG_N" -eq 25 ] || red "the number of rastergen rows is not 25 ($RG_N)"
[ "$JC_N" -eq 7 ] || red "the number of jobcheck rows is not 7 ($JC_N)"
[ "$OUT_N" -eq 8 ] || red "the number of rows that pass -o dir is not 8 ($OUT_N)"
[ "$ART_N" -eq 7 ] || red "the number of rows that leave products is not 7 ($ART_N)"
[ "$RC0_N" -eq 39 ] || red "the number of rc 0 rows is not 39 ($RC0_N)"
[ "$RC1_N" -eq 4 ] || red "the number of rc 1 rows is not 4 ($RC1_N)"
[ "$RC2_N" -eq 8 ] || red "the number of rc 2 rows is not 8 ($RC2_N)"
[ "$PIN_N" -eq 6 ] || red "the number of identity pins is not 6 ($PIN_N)"

SUITE_ENV="SPINEL_E170_MODE=$MODE ${REC_OS:+SPINEL_GOLDEN_OS=$REC_OS} LC_ALL=C LLVM=${LLVM:-/usr/lib/llvm-22} LLVM_PREFIX=${LLVM_PREFIX:-/usr/lib/llvm-22}"
case "$INJECT" in
  ruby-absent)
    echo "  INJECT ruby-absent: point the 3 Ruby tools at a missing dir"
    SUITE_ENV="$SUITE_ENV SPINEL_E170_RUBY=$TMP/no-such-ruby" ;;
  header-drift)
    echo "  INJECT header-drift: lengthen the expected sp_job_table.h by 1 byte"
    SUITE_ENV="$SUITE_ENV SPINEL_E170_HEADER_DRIFT=1" ;;
  class-drift)
    echo "  INJECT class-drift: invert the expected rc of 1 accepted row (jt_check_header)"
    SUITE_ENV="$SUITE_ENV SPINEL_E170_CLASS_DRIFT=1" ;;
  pin-drift)
    echo "  INJECT pin-drift: shift the pin of the frozen spinel-jobtable by 1 character"
    SUITE_ENV="$SUITE_ENV SPINEL_E170_PIN_DRIFT=1" ;;
  case-skip)
    echo "  INJECT case-skip: drop 1 row from the corpus to try to get green"
    SUITE_ENV="$SUITE_ENV SPINEL_E170_CASE_SKIP=jt_emit_stdout" ;;
  golden-absent)
    echo "  INJECT golden-absent: point the golden fixture at a missing dir (a skip does not make it green)"
    SUITE_ENV="$SUITE_ENV SPINEL_E170_GOLDEN=$TMP/no-such-golden" ;;
  golden-drift)
    echo "  INJECT golden-drift: lengthen the product's output by 1 byte so it differs from the golden"
    SUITE_ENV="$SUITE_ENV SPINEL_E170_GOLDEN_DRIFT=1" ;;
esac

if [ "$INJECT" = suite-skip ]; then
  echo "  INJECT suite-skip: remove the suite run"
  SUITE_RC=0
  : > "$TMP/suite.out"
else
  # shellcheck disable=SC2086
  env $SUITE_ENV ruby "$HERE/test_e170.rb" > "$TMP/suite.out" 2>&1
  SUITE_RC=$?
fi
SUITE_LINE=$(grep -a -oE '[0-9]+ runs, [0-9]+ assertions, [0-9]+ failures, [0-9]+ errors' "$TMP/suite.out" | head -1)
[ -n "$SUITE_LINE" ] || red "the suite was not run — an isolated suite is not called evidence"
[ "$SUITE_RC" -eq 0 ] || red "the suite is red (rc=$SUITE_RC): ${SUITE_LINE:-no output}"
if [ "$SUITE_RC" -eq 0 ] && [ -n "$SUITE_LINE" ]; then
  _r=$(printf '%s\n' "$SUITE_LINE" | sed -n 's/^\([0-9]*\) runs.*/\1/p')
  [ "$_r" = "9" ] || red "green, but the suite does not have 9 tests ($_r) — deleting tests does not make it green"
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
echo "$PROG:   evidence controls=$(set -- $INJECT_TOKENS; echo $(($# - 1))) active=$INJECT"

GOLDEN_N=$(ls -1 "$GOLDEN_DIR" 2>/dev/null | grep -c -v '\.tsv$')
# At the first checkpoint the suite counts "golden == the frozen tool's raw output" (mode=both/record).
# Once the default is golden only (second checkpoint), drift becomes `-`.
DRIFT=0
[ "$MODE" = golden ] && DRIFT=-

if [ "$fails" -eq 0 ]; then
  echo "$PROG: PASS cases=$DECL_N identical=$DECL_N jobtable=$JT_N rastergen=$RG_N jobcheck=$JC_N outdir=$OUT_N artifacts=$ART_N header=1 pins=$PIN_N evidence=7 golden=$GOLDEN_N drift=$DRIFT"
  exit 0
fi
echo "$PROG: FAIL ($fails)"
exit 1
