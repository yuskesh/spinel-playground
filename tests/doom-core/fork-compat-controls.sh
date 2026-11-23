#!/bin/sh
#
# tests/doom-core/fork-compat-controls.sh — what fork-compat.sh would have to
# notice.
#
# The harness reports which of the predecessor fork's defects the pinned
# compiler still has. That report is only worth reading if the harness cannot
# be fooled into agreeing with a fixture that is not the fork's, into calling
# an unmeasured row a result, or into guessing a compiler. Each control here
# breaks one of those and requires the named refusal.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FC="$ROOT/tests/doom-core/fork-compat.sh"
LEDGER="$ROOT/tests/doom-core/fork/ledger.tsv"
FIX="$ROOT/tests/doom-core/fork/fixtures"

die() { echo "fork-controls: $*" >&2; exit 1; }
[ -f "$FC" ] || die "no harness at $FC"
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG
elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang
else die "set LLVM_PREFIX (or CLANG); these controls measure the same toolchain the harness does"
fi

RUBY_BIN=${RUBY:-ruby}
command -v "$RUBY_BIN" >/dev/null 2>&1 || die "no ruby at $RUBY_BIN"
TAB=$(printf "\\t")
W=$(mktemp -d "${TMPDIR:-/tmp}/fork-controls.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM
pass=0; fail=0
want() { if grep -qE "$3" "$2"; then echo "  pass $1"; pass=$((pass + 1));
         else echo "  FAIL $1"; sed 's/^/        /' "$2" | tail -5; fail=$((fail + 1)); fi; }
reject() { if grep -qE "$3" "$2"; then echo "  FAIL $1 (the wrong answer is present)"; fail=$((fail + 1));
           else echo "  pass $1"; pass=$((pass + 1)); fi; }

# A copy of the tree the harness reads, so a control can corrupt one file
# without touching the repository. Only the pieces fork-compat.sh opens.
mk() { # dest
  mkdir -p "$1/tests/doom-core/fork" "$1/vendor/spinel/bin"
  cp "$FC" "$1/tests/doom-core/fork-compat.sh"
  cp "$LEDGER" "$1/tests/doom-core/fork/ledger.tsv"
  cp -R "$FIX" "$1/tests/doom-core/fork/fixtures"
  ln -s "$ROOT/vendor/spinel/bin/spinel" "$1/vendor/spinel/bin/spinel"
}
run() { # dir outfile [env...]
  d=$1; out=$2; shift 2
  ( cd "$d" && env "$@" sh "$d/tests/doom-core/fork-compat.sh" ) > "$out" 2>&1 && echo 0 > "$out.rc" || echo $? > "$out.rc"
}

echo "== a fixture that is not the fork's is refused =="
# The ledger carries each reproducer's sha256 because a fixture that has been
# edited no longer measures what the fork measured. One byte is enough.
mk "$W/tamper"
printf '\n# one byte that is not the fork'"'"'s\n' >> "$W/tamper/tests/doom-core/fork/fixtures/module_ivar_from_includer.rb"
run "$W/tamper" "$W/tamper.out" "LLVM_PREFIX=${LLVM_PREFIX:-}" "CLANG=$CC_BIN"
want   "the edited reproducer is named"      "$W/tamper.out" 'B15 *ERROR .*module_ivar_from_includer\.rb is sha256'
want   "and the run fails"                   "$W/tamper.out.rc" '^[1-9]'
reject "it is not reported as a measurement" "$W/tamper.out" 'B15 *not-reproduced'

echo "== a row whose fixture is absent is an error, not a pass =="
mk "$W/absent"
rm -f "$W/absent/tests/doom-core/fork/fixtures/return_type_renarrow.rb"
run "$W/absent" "$W/absent.out" "LLVM_PREFIX=${LLVM_PREFIX:-}" "CLANG=$CC_BIN"
want   "the missing reproducer is named" "$W/absent.out" 'B16 *ERROR .*return_type_renarrow\.rb, which is not in the fixtures'
want   "and the run fails"                "$W/absent.out.rc" '^[1-9]'
want   "and it is counted as an error"    "$W/absent.out" 'errors 1'
reject "not as a measurement"             "$W/absent.out" 'B16 *not-reproduced'

echo "== the verdict follows the bytes =="
# B16 comes back `fixed` against the real tree. Change what the fork expects
# and the same run must say the defect is present -- otherwise `fixed` was not
# a comparison.
mk "$W/flip"
printf 'not what the fork expected\n' > "$W/flip/tests/doom-core/fork/fixtures/return_type_renarrow.rb.expected"
run "$W/flip" "$W/flip.out" "LLVM_PREFIX=${LLVM_PREFIX:-}" "CLANG=$CC_BIN"
want   "a changed expectation flips the verdict" "$W/flip.out" 'B16 *DISAGREES'
want   "and names both the pin and the run"      "$W/flip.out" 'the ledger pins not-reproduced, this run measured reproduced'
reject "the old verdict is gone"                 "$W/flip.out" 'B16 *not-reproduced/'

echo "== every ledger row is accounted for =="
mk "$W/whole"
run "$W/whole" "$W/whole.out" "LLVM_PREFIX=${LLVM_PREFIX:-}" "CLANG=$CC_BIN"
total=$(grep -vc '^#' "$LEDGER")
want "all $total rows are accounted for"        "$W/whole.out" "$total of $total ledger row\(s\) accounted for"
want "source rows are printed on their own"     "$W/whole.out" 'source provenance \(not execution\)'
want "unrun rows say they are not a pass"       "$W/whole.out" 'not executed \(no reproducer; not a pass\)'
want "and the summary separates the three"      "$W/whole.out" 'executed [0-9]+ \(agreeing with the ledger [0-9]+, disagreeing [0-9]+\), not executed [0-9]+, source [0-9]+'
# A deferred row must never appear as a measurement.
for id in B3 B4 B5 B6 BATCH10 BATCH11; do
  reject "$id is not reported as measured" "$W/whole.out" "^  $id +(not-)?reproduced/"
done

echo "== the ledger cannot outlive the measurement =="
# run_status is a pinned measurement, not a plan. Flip one row's and the run
# must say the two disagree and fail, or the ledger could drift for a release
# and nobody would find out from a green run.
mk "$W/stale"
"$RUBY_BIN" -e 'p=ARGV[0]; t=File.read(p);
  o = t.lines.find { |l| l.start_with?("B1\t") } or abort("no B1 row");
  n = o.sub("not-reproduced", "reproduced");
  abort("the flip changed nothing") if n == o;
  File.write(p, t.sub(o) { n })' "$W/stale/tests/doom-core/fork/ledger.tsv" \
  || die "could not build the stale-ledger control"
run "$W/stale" "$W/stale.out" "LLVM_PREFIX=${LLVM_PREFIX:-}" "CLANG=$CC_BIN"
want   "a stale run_status is named"   "$W/stale.out" 'B1 +DISAGREES the ledger pins reproduced, this run measured not-reproduced'
want   "and the run fails"             "$W/stale.out.rc" '^[1-9]'
want   "and it is counted as an error" "$W/stale.out" 'disagreeing 1'

echo "== the toolchain is named, not guessed =="
# An unset LLVM_PREFIX is how a Stage 1 run silently used a different compiler
# and produced a number nobody could reproduce.
mk "$W/noenv"
( cd "$W/noenv" && env -u LLVM_PREFIX -u CLANG sh "$W/noenv/tests/doom-core/fork-compat.sh" ) \
  > "$W/noenv.out" 2>&1 && echo 0 > "$W/noenv.out.rc" || echo $? > "$W/noenv.out.rc"
want   "it refuses to guess a compiler" "$W/noenv.out" 'refuses to guess'
want   "and exits nonzero"              "$W/noenv.out.rc" '^[1-9]'
reject "and measures nothing"           "$W/noenv.out" 'executed [0-9]'

echo "== the review reports what was measured =="
# Stage 1 lesson: a figure that appears anywhere in a document is not checked.
# Each is matched inside its own row of the review.
REV="$ROOT/docs/core/doom-stage2-fork-review.md"
[ -f "$REV" ] || die "no fork review at $REV"
want "the review carries the run" "$REV" '^LLVM_PREFIX=/opt/llvm-23.1.1 sh tests/doom-core/fork-compat.sh$'
want "and the totals it measured" "$REV" 'Executed 12, all agreeing with the ledger.*Not executed 7.*Source 10'
reviewrow() { grep -E "^\\| $2 \\|" "$REV" > "$W/revrow" 2>/dev/null || : > "$W/revrow"; want "$1" "$W/revrow" "$3"; }
reviewrow "B2 is recorded present"       "B2"  '0/5 runs'
reviewrow "B13 carries its measurement"  "B13" 'record\.rb:77'
reviewrow "B1 is recorded fixed"         "B1"  '5/5'
reviewrow "B15 is recorded fixed"        "B15" '5/5'
# And the same numbers from the run, not from the file.
run "$W/whole" "$W/whole2.out" "LLVM_PREFIX=${LLVM_PREFIX:-}" "CLANG=$CC_BIN"
want "the run agrees on the totals" "$W/whole2.out" 'executed 12 \(agreeing with the ledger 12, disagreeing 0\), not executed 7, source 10'

echo "fork-controls: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" -eq 0 ] || exit 1
