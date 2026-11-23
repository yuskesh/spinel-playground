#!/bin/sh
#
# tests/doom-core/run-controls.sh — what tests/doom-core/run.sh refuses.
#
#   sh tests/doom-core/run-controls.sh [DIR]
#
# Decision 0008 task 9 asks for two of these by name: "Break an oracle
# executable and remove a lane to prove neither is reported as success." A
# runner that aggregates other suites can fail in ways none of those suites
# can see, so each control below PLANTS ITS OWN DEFECT in a copied lane
# directory and requires run.sh to name it:
#
#   * a suite on disk that the lane table does not list -- the drift that made
#     this runner necessary, in the one place that can still hide it;
#   * a lane table row with no file behind it;
#   * A LANE THAT EXITS 0 AND REPORTS A FAILURE, which is the reason the runner
#     reads the summary at all rather than trusting the status;
#   * a lane that exits nonzero while reporting none, which is the same
#     mistake in the other direction;
#   * a lane that prints no summary line: a suite that died before reporting
#     has not reported that nothing failed.
#
# THE PLANTED LANES ARE THREE-LINE SCRIPTS, not copies of real suites: what is
# under test is the runner's accounting, and a real suite would take an hour to
# say the same thing.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
RUN="$ROOT/tests/doom-core/run.sh"
DIR=${1:-${TMPDIR:-/tmp}/doom-core-run-controls.$$}
TAB=$(printf "\t")
pass=0; fail=0
want() { # label file pattern
  if grep -qE "$3" "$2"; then echo "  pass $1"; pass=$((pass + 1))
  else echo "  FAIL $1"; sed 's/^/        /' "$2" | tail -6; fail=$((fail + 1)); fi
}
reject() { # label file pattern
  if grep -qE "$3" "$2"; then echo "  FAIL $1 (the wrong answer is present)"; fail=$((fail + 1))
  else echo "  pass $1"; pass=$((pass + 1)); fi
}
mkdir -p "$DIR"

# A lane directory of our own: one lane that passes, and a table that lists it.
plant() { # dir
  rm -rf "$1"; mkdir -p "$1"
  printf '#!/bin/sh\necho "good: 2 checked, 2 pass, 0 fail"\n' > "$1/good.sh"
  printf '#lane\trole\tsummary\tneeds\tnote\n' > "$1/lanes.tsv"
  printf 'good.sh\ttop\tchecked:good\t-\ta lane that passes\n' >> "$1/lanes.tsv"
}
runner() { # dir outfile
  LANEDIR="$1" LANES="$1/lanes.tsv" sh "$RUN" "$1/out" > "$2" 2>&1 || true
}

echo "== the runner accounts for every suite in the directory =="
plant "$DIR/base"
runner "$DIR/base" "$DIR/base.out"
want   "a lane directory that matches its table passes"  "$DIR/base.out" '^run: 5 checked, 5 pass, 0 fail'
# THE CONTROL TASK 9 ASKS FOR: a suite nobody listed.
plant "$DIR/unlisted"
printf '#!/bin/sh\necho "stray: 1 checked, 1 pass, 0 fail"\n' > "$DIR/unlisted/stray.sh"
runner "$DIR/unlisted" "$DIR/unlisted.out"
want   "a suite the table does not list is named"        "$DIR/unlisted.out" "FAIL and leaves no suite unlisted \(got 'stray.sh '"
reject "and the run is not a success"                    "$DIR/unlisted.out" '^run: [0-9]+ checked, [0-9]+ pass, 0 fail'
# And the other direction: a row whose file was removed.
plant "$DIR/missing"
printf 'gone.sh\ttop\tchecked:gone\t-\ta lane that is not there\n' >> "$DIR/missing/lanes.tsv"
runner "$DIR/missing" "$DIR/missing.out"
want   "a listed suite that is not there is named"       "$DIR/missing.out" "FAIL the table names no suite that is not there \(got 'gone.sh '"

echo "== a lane's own summary decides it, not its exit status =="
# EXIT 0 AND A FAILURE REPORTED. This is the shape that would make a runner
# report a green total over a red suite.
plant "$DIR/zerofail"
printf '#!/bin/sh\necho "  FAIL something the lane checks"\necho "good: 2 checked, 1 pass, 1 fail"\nexit 0\n' > "$DIR/zerofail/good.sh"
runner "$DIR/zerofail" "$DIR/zerofail.out"
want   "a lane that exits 0 and reports a failure is a failure" "$DIR/zerofail.out" '^  FAIL good\.sh \(exit 0, [0-9]+s\): good: 2 checked, 1 pass, 1 fail'
want   "and the lane's own FAIL lines are shown"                "$DIR/zerofail.out" 'FAIL something the lane checks'
reject "and the run is not a success"                           "$DIR/zerofail.out" '^run: [0-9]+ checked, [0-9]+ pass, 0 fail'
# The mirror: a clean summary and a nonzero status.
plant "$DIR/failzero"
printf '#!/bin/sh\necho "good: 2 checked, 2 pass, 0 fail"\nexit 3\n' > "$DIR/failzero/good.sh"
runner "$DIR/failzero" "$DIR/failzero.out"
want   "a lane that reports none and exits nonzero is a failure" "$DIR/failzero.out" '^  FAIL good\.sh \(exit 3, [0-9]+s\)'
# And silence.
plant "$DIR/silent"
printf '#!/bin/sh\necho "this lane says nothing a runner can read"\nexit 0\n' > "$DIR/silent/good.sh"
runner "$DIR/silent" "$DIR/silent.out"
want   "a lane that prints no summary is a failure, named as absent" "$DIR/silent.out" '^  FAIL good\.sh: no good summary line in '

echo "== a summary kind the runner cannot read is refused, not assumed =="
plant "$DIR/kind"
sed 's/checked:good/counted:good/' "$DIR/kind/lanes.tsv" > "$DIR/kind/lanes.new" && mv "$DIR/kind/lanes.new" "$DIR/kind/lanes.tsv"
runner "$DIR/kind" "$DIR/kind.out"
want   "an unknown summary kind is named" "$DIR/kind.out" 'lanes\.tsv gives the summary kind counted, which this runner does not read'

echo "run-controls: $((pass + fail)) checked, $pass pass, $fail fail"
[ "$fail" -eq 0 ]
