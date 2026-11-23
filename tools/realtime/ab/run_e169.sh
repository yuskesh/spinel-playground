#!/bin/sh
# run_e169.sh — the single canonical entry of E169 (byte equality of the native spinel-rtcheck).
#
# The skeleton follows the earlier runners: RepoGuard watches writes to the
# repository, INJECT is a closed set, and a summary line is printed. **The suite is always started**.
#
# What is compared is stdout / stderr / rc plus the 4 files of `-o` (design D-1).
# The suite also checks every time that the vocabulary is in one place (D-2).
set -u
# An oracle (tests/ORACLES.tsv): it runs only on the owner's instruction.
"$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)/tools/oracle/gate" tools/realtime/ab/run_e169.sh whole || exit 0

PROG=e169
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
TAB="$REPO/docs/experiments/results/E169/cases.tsv"
IDT="$REPO/docs/experiments/results/E169/identity.tsv"

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
GOLDEN_DIR="$REPO/docs/experiments/results/E169/golden"

# `vocab-drift` was retired together with its subject (the frozen Python is gone, so nothing is left to compare
# the tsv with). 9 -> 8 tokens.
INJECT_TOKENS="none suite-skip native-absent class-drift pin-drift case-skip golden-absent golden-drift"
INJECT="${SPINEL_E169_INJECT:-none}"
# The real number of positive controls (excluding `none`). **Not written twice, in the summary and the diagnostic** — once,
# the same number had 3 readers and only one was fixed. Here
# `evidence=` (summary) and `controls=` (diagnostic) come from the same variable.
EVIDENCE_N=$(set -- $INJECT_TOKENS; echo $(($# - 1)))
_known=0
for t in $INJECT_TOKENS; do [ "$t" = "$INJECT" ] && _known=1; done
[ "$_known" -eq 1 ] || fatal "unknown SPINEL_E169_INJECT='$INJECT' (closed set: $INJECT_TOKENS)"

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
DECL_N=$(awk -F"$TAB_C" 'NR>1 && NF>=7 {n++} END {print n+0}' "$TAB")
OUT_N=$(awk -F"$TAB_C" 'NR>1 && $4 ~ /@OUT@/ {n++} END {print n+0}' "$TAB")
RC0_N=$(awk -F"$TAB_C" 'NR>1 && $5=="0" {n++} END {print n+0}' "$TAB")
RC1_N=$(awk -F"$TAB_C" 'NR>1 && $5=="1" {n++} END {print n+0}' "$TAB")
RC2_N=$(awk -F"$TAB_C" 'NR>1 && $5=="2" {n++} END {print n+0}' "$TAB")
PIN_N=$(awk -F"$TAB_C" 'NR>1 && NF==2 {n++} END {print n+0}' "$IDT")
VOCAB="$REPO/tools/realtime/alloc_vocabulary.tsv"
ALLOC_N=$(awk -F"$TAB_C" '$1=="alloc" {n++} END {print n+0}' "$VOCAB")
PAUSE_N=$(awk -F"$TAB_C" '$1=="pause" {n++} END {print n+0}' "$VOCAB")
CTOR_N=$(awk -F"$TAB_C" '$1=="constructor" {n++} END {print n+0}' "$VOCAB")
[ "$DECL_N" -eq 21 ] || red "the number of cases is not 21 ($DECL_N)"
[ "$OUT_N" -eq 4 ] || red "the number of rows that compare -o is not 4 ($OUT_N)"
[ "$RC0_N" -eq 4 ] || red "the number of rc 0 rows is not 4 ($RC0_N)"
[ "$RC1_N" -eq 16 ] || red "the number of rc 1 rows is not 16 ($RC1_N)"
[ "$RC2_N" -eq 1 ] || red "the number of rc 2 rows is not 1 ($RC2_N)"
# 7 -> 6 (the SHA pin of the frozen `spinel_alloc_free.py` was retired).
# **This number is also in the suite's SHAPE["pins"]**.
[ "$PIN_N" -eq 6 ] || red "the number of identity pins is not 6 ($PIN_N)"
# The breakdown of the 31 words the undef gate reads (the same number as the native static_assert).
[ "$ALLOC_N" -eq 19 ] || red "the number of alloc entries in the vocabulary is not 19 ($ALLOC_N)"
[ "$PAUSE_N" -eq 8 ] || red "the number of pause entries in the vocabulary is not 8 ($PAUSE_N)"
[ "$CTOR_N" -eq 4 ] || red "the number of constructor entries in the vocabulary is not 4 ($CTOR_N)"

SUITE_ENV="SPINEL_E169_MODE=$MODE ${REC_OS:+SPINEL_GOLDEN_OS=$REC_OS} LC_ALL=C LLVM_PREFIX=${LLVM_PREFIX:-/usr/lib/llvm-22}"
case "$INJECT" in
  native-absent)
    echo "  INJECT native-absent: point the native spinel-rtcheck at a missing path"
    SUITE_ENV="$SUITE_ENV SPINEL_E169_NATIVE=$TMP/no-such-rtcheck" ;;
  class-drift)
    echo "  INJECT class-drift: invert the expected rc of 1 accepted row (pin_region)"
    SUITE_ENV="$SUITE_ENV SPINEL_E169_CLASS_DRIFT=1" ;;
  pin-drift)
    echo "  INJECT pin-drift: shift the pin of alloc_vocabulary.tsv by 1 character"
    SUITE_ENV="$SUITE_ENV SPINEL_E169_PIN_DRIFT=1" ;;
  case-skip)
    echo "  INJECT case-skip: drop 1 row from the corpus to try to get green"
    SUITE_ENV="$SUITE_ENV SPINEL_E169_CASE_SKIP=pin_strict" ;;
  golden-absent)
    echo "  INJECT golden-absent: point the golden fixture at a missing dir (a skip does not make it green)"
    SUITE_ENV="$SUITE_ENV SPINEL_E169_GOLDEN=$TMP/no-such-golden" ;;
  golden-drift)
    echo "  INJECT golden-drift: lengthen the product's output by 1 byte so it differs from the golden"
    SUITE_ENV="$SUITE_ENV SPINEL_E169_GOLDEN_DRIFT=1" ;;
esac

if [ "$INJECT" = suite-skip ]; then
  echo "  INJECT suite-skip: remove the suite run"
  SUITE_RC=0
  : > "$TMP/suite.out"
else
  # shellcheck disable=SC2086
  env $SUITE_ENV ruby "$HERE/test_e169.rb" > "$TMP/suite.out" 2>&1
  SUITE_RC=$?
fi
SUITE_LINE=$(grep -a -oE '[0-9]+ runs, [0-9]+ assertions, [0-9]+ failures, [0-9]+ errors' "$TMP/suite.out" | head -1)
[ -n "$SUITE_LINE" ] || red "the suite was not run — an isolated suite is not called evidence"
[ "$SUITE_RC" -eq 0 ] || red "the suite is red (rc=$SUITE_RC): ${SUITE_LINE:-no output}"
if [ "$SUITE_RC" -eq 0 ] && [ -n "$SUITE_LINE" ]; then
  _r=$(printf '%s\n' "$SUITE_LINE" | sed -n 's/^\([0-9]*\) runs.*/\1/p')
  [ "$_r" = "10" ] || red "green, but the suite does not have 10 tests ($_r) — deleting tests does not make it green"
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
  echo "$PROG: PASS cases=$DECL_N identical=$DECL_N outdir=$OUT_N rc0=$RC0_N rc1=$RC1_N rc2=$RC2_N vocab=$((ALLOC_N + PAUSE_N + CTOR_N)) pins=$PIN_N evidence=$EVIDENCE_N golden=$GOLDEN_N drift=$DRIFT"
  exit 0
fi
echo "$PROG: FAIL ($fails)"
exit 1
