#!/bin/sh
#
# tests/doom-core/run.sh — every suite in tests/doom-core, enumerated and run.
#
#   [SELECT="audit source-pack"] [REQUIRE_ALL=1] sh tests/doom-core/run.sh [DIR]
#
# Decision 0008 task 9. Until this existed, WHICH SUITES RAN WAS MAINTAINED BY
# MEMORY: there is no CI here, each suite is its own script with its own
# environment, and a suite nobody remembered was a suite nobody ran. The
# enumeration is tests/doom-core/lanes.tsv and THE FIRST CHECK IS THAT IT AND
# THE DIRECTORY AGREE, in both directions -- a suite on disk with no row is a
# lane nobody runs, a row with no file is a lane nobody can run. Neither is
# reported as success.
#
# WHAT IT RUNS. The rows whose role is `top`. The rows marked `under:NAME` are
# run BY that suite -- verify.sh runs five of them itself, over artifacts it has
# just built -- and running them again here would report the same checks twice
# and build everything twice. `subject:NAME` is a suite another one runs against
# copied trees. Every row is printed either way, with its role, so the record
# says what ran and what it was accounted for by.
#
# WHAT IT READS FROM EACH LANE is the lane's own summary line, named per row in
# lanes.tsv, because the suites do not all count the same things: most print
# "N checked, N pass, N fail"; fork-compat prints executed and not-executed rows
# (a documented nonapplicable row is not a pass); loop-reports prints passed and
# failed. A lane whose summary line is absent FAILS, whatever it exited with: a
# suite that died before printing one has not reported that nothing failed.
#
# REQUIRE_ALL=1 is passed to every lane, where it turns that lane's own skips
# into failures, and it also makes SELECT an error here: a narrowed run is not
# the gate.
#
# THE ENVIRONMENT IS THE LANES', NOT THIS FILE'S. Each suite documents what it
# needs and skips or fails on its own terms; this runner sets nothing, so a lane
# that skips here skips for the same reason it would alone. WHAT IT DOES DO IS
# SAY WHAT IS MISSING FIRST: lanes.tsv's `needs` column is checked before any
# lane runs and the absences are printed with the lanes they affect. On
# 2026-09-18 a four-hour REQUIRE_ALL run ended red on two absences that were
# knowable at second zero -- a harness directory screens needs, and a kernel too
# old for loop-reports -- and neither is in docs/building.md.
#
# LANEDIR and LANES exist for tests/doom-core/run-controls.sh, which points them
# at copied trees to plant a missing lane, an unlisted file, a lane that fails
# and a lane that prints no summary.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LANEDIR=${LANEDIR:-$ROOT/tests/doom-core}
LANES=${LANES:-$LANEDIR/lanes.tsv}
DIR=${1:-${TMPDIR:-/tmp}/doom-core-run.$$}
TAB=$(printf "\t")
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
mkdir -p "$DIR" || exit 2
[ -f "$LANES" ] || { echo "run: no lane table at $LANES" >&2; exit 2; }

echo "== the lane table and the directory are the same set =="
awk -F"$TAB" '!/^#/ && NF >= 5 { print $1 }' "$LANES" | sort > "$DIR/l.table"
( cd "$LANEDIR" && ls *.sh 2>/dev/null ) | grep -v '^run\.sh$' | sort > "$DIR/l.disk"
ok "there are lanes to compare at all" "$([ -s "$DIR/l.disk" ] && echo yes)" "yes"
ok "the table names no suite that is not there" "$(comm -13 "$DIR/l.disk" "$DIR/l.table" | tr '\n' ' ')" ""
ok "and leaves no suite unlisted"                "$(comm -23 "$DIR/l.disk" "$DIR/l.table" | tr '\n' ' ')" ""

# The roles, printed before anything runs: the record says what this runner is
# accountable for and what it is leaving to another suite.
echo "== the lanes =="
awk -F"$TAB" '!/^#/ && NF >= 5 { printf "  %-26s %-28s %s\n", $1, $2, $5 }' "$LANES"

# WHAT IS MISSING, BEFORE ANYTHING RUNS. A four-hour run that ends red on an
# absence knowable at second zero punishes the operator for a documentation gap;
# silencing the lane instead hides it. So the preconditions each lane names in
# lanes.tsv are checked here and the missing ones are printed with the lanes
# they affect -- and then everything runs anyway, because it is the operator's
# call whether a partial run is worth having, and because a lane that fails for
# a missing tool must still say so in its own words.
echo "== the preconditions the lanes name =="
miss_any=""
for lane in $(awk -F"$TAB" '!/^#/ && NF >= 5 && $2 == "top" { print $1 }' "$LANES"); do
  lane_needs=$(awk -F"$TAB" -v l="$lane" '!/^#/ && $1 == l { print $4 }' "$LANES")
  [ "$lane_needs" = "-" ] && continue
  lane_missing=""
  for need in $lane_needs; do
    case $need in
      kernel:*)
        opt=${need#kernel:}
        k=${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}
        if [ ! -x "$k" ] || "$k" "$opt" 2>&1 | grep -q "unknown option $opt"; then
          lane_missing="$lane_missing $need"
        fi ;;
      *"|"*)
        a=${need%%|*}; b=${need#*|}
        eval "av=\${$a:-}; bv=\${$b:-}"
        [ -n "$av" ] || [ -n "$bv" ] || lane_missing="$lane_missing $need" ;;
      *)
        eval "v=\${$need:-}"
        [ -n "$v" ] || lane_missing="$lane_missing $need" ;;
    esac
  done
  if [ -n "$lane_missing" ]; then
    echo "  MISSING $lane:$lane_missing"
    miss_any=yes
  fi
done
if [ -n "$miss_any" ]; then
  echo "  the lanes above will not check everything they have; they are run anyway and will say so themselves"
else
  echo "  pass every precondition the lanes name is present"
  pass=$((pass + 1))
fi

tops=$(awk -F"$TAB" '!/^#/ && NF >= 3 && $2 == "top" { print $1 }' "$LANES")
if [ -n "${SELECT:-}" ]; then
  [ "${REQUIRE_ALL:-}" = 1 ] && { echo "run: SELECT and REQUIRE_ALL=1 together: a narrowed run is not the gate" >&2; exit 2; }
  sel=""
  for want in $SELECT; do
    found=""
    for t in $tops; do [ "$t" = "$want" ] || [ "$t" = "$want.sh" ] && found=$t; done
    [ -n "$found" ] || { echo "run: SELECT names $want, which is not a top-level lane" >&2; exit 2; }
    sel="$sel $found"
  done
  tops=$sel
  echo "  (SELECT: this run is$sel, and is not the gate)"
fi

# One lane. Answers nothing; prints its own line and counts.
run_lane() { # file summary-spec
  lane=$1; spec=$2
  kind=${spec%%:*}; label=${spec#*:}
  s=$(date +%s)
  # EVERY LANE IS GIVEN A DIRECTORY, because they do not agree about wanting
  # one: most make their own with mktemp and ignore an argument, screens.sh,
  # verify.sh and run-controls.sh take an optional one, and loop-reports.sh
  # REQUIRES one and exits 2 without it -- which is how a runner that passed
  # none found it.
  #
  # SELECT IS THIS RUNNER'S OWN NARROWING AND NOT A LANE'S. Passing it down
  # reaches any lane that reads it -- run-controls.sh runs this runner again
  # over planted directories, and inherited a SELECT naming a lane those
  # directories do not have. REQUIRE_ALL is the opposite: each lane turns its
  # own skips into failures with it, so it is left in place.
  mkdir -p "$DIR/$lane.d"
  SELECT= sh "$LANEDIR/$lane" "$DIR/$lane.d" > "$DIR/$lane.out" 2>&1
  rc=$?
  took=$(( $(date +%s) - s ))
  case $kind in
    checked) line=$(grep -E "^$label: [0-9]+ checked, [0-9]+ pass, [0-9]+ fail" "$DIR/$lane.out" | tail -1)
             got=$(echo "$line" | sed -n 's/^.* \([0-9]*\) fail.*/\1/p') ;;
    executed) line=$(grep -E "^$label: executed [0-9]+ " "$DIR/$lane.out" | tail -1)
              got=$(echo "$line" | sed -n 's/^.*errors \([0-9]*\).*/\1/p') ;;
    passed)  line=$(grep -E "^$label: [0-9]+ passed, [0-9]+ failed" "$DIR/$lane.out" | tail -1)
             got=$(echo "$line" | sed -n 's/^.*, \([0-9]*\) failed.*/\1/p') ;;
    *) echo "  FAIL $lane: lanes.tsv gives the summary kind $kind, which this runner does not read"
       fail=$((fail + 1)); return ;;
  esac
  if [ -z "$line" ]; then
    # A LANE THAT PRINTED NO SUMMARY HAS NOT REPORTED ANYTHING, and its exit
    # status alone is not the claim: several suites exit 1 while incomplete.
    echo "  FAIL $lane: no $label summary line in $DIR/$lane.out (exit $rc, ${took}s)"
    # ITS OWN WORDS, HERE, when it said why. A lane that reports itself DORMANT
    # -- it needs a tool nobody has built, say -- has given the reason already,
    # and a reader who only sees "no summary line in FILE" has to go and find
    # what the lane already said.
    sed -n 's/^[a-z-]*: DORMANT/      DORMANT/p;s/^[a-z-]*:   \(.*\)$/        \1/p' "$DIR/$lane.out" | head -6
    fail=$((fail + 1))
    return
  fi
  if [ "$rc" -eq 0 ] && [ "${got:-1}" = 0 ]; then
    echo "  pass $lane (${took}s): $line"
    pass=$((pass + 1))
  else
    echo "  FAIL $lane (exit $rc, ${took}s): $line"
    # THE LANE'S OWN FAIL LINES, still saying FAIL: an excerpt that drops the
    # word reads like a list of things that were checked.
    sed -n 's/^  FAIL /      FAIL /p' "$DIR/$lane.out" | head -5
    fail=$((fail + 1))
  fi
}

echo "== the lanes run =="
T0=$(date +%s)
for lane in $tops; do
  spec=$(awk -F"$TAB" -v l="$lane" '!/^#/ && $1 == l { print $3 }' "$LANES")
  run_lane "$lane" "$spec"
done
echo "run: $((pass + fail)) checked, $pass pass, $fail fail; $(( $(date +%s) - T0 )) s in the lanes, output under $DIR"
[ "$fail" -eq 0 ]
exit $?
