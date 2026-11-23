#!/bin/sh
# tests/app/run.sh -- every tests/app suite of decision 0014, in one run.
#
# The list below plus the excluded suites and the files on disk must agree in
# both directions: a suite added without being listed, or listed and removed,
# fails the runner before anything runs. Each suite is run as its own `sh` process with the caller's
# environment, so REQUIRE_ALL=1 reaches every one of them and turns each of
# their skips into a failure. REQUIRE_ALL only proves the suites RAN; what
# they establish is the plan's Coverage table (0014 plan, Task 13).
#
# Prints each suite's final count line and its wall time, then a summary;
# exits 1 if any suite failed.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIR="$ROOT/tests/app"

SUITES="board build channel contract cross effects host int-width lowering platform-facts reserves stress udp verify"
# not run here: doom-admission needs two kernels, and it is an oracle (a
# baseline-kernel comparison) that runs only on the owner's instruction;
# session (decision 0021) needs DEMO1's session image and the DOOM entries
# built for thumbv8m, which the board lane makes and then runs it with
EXCLUDED="doom-admission session"

on_disk=$(cd "$DIR" && ls ./*.sh | sed 's|^\./||; s|\.sh$||' | grep -vx run | LC_ALL=C sort | tr '\n' ' ')
listed=$(echo "$SUITES $EXCLUDED" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')
if [ "$on_disk" != "$listed" ]; then
  echo "run: the suite list and tests/app/*.sh disagree"
  echo "  listed + excluded: $listed"
  echo "  on disk: $on_disk"
  exit 1
fi

failed=""
for s in $SUITES; do
  t0=$(date +%s)
  if out=$(sh "$DIR/$s.sh" 2>&1); then rc=0; else rc=$?; fi
  # each suite's own last summary line: `N checked, ...`, or platform-facts'
  # `N required facts failed, ...`
  last=$(printf '%s\n' "$out" | grep -E "^$s: [0-9]+ " | tail -1)
  echo "$s: ${last#"$s: "} [rc $rc, $(( $(date +%s) - t0 )) s]"
  if [ "$rc" != 0 ]; then
    failed="$failed $s"
    printf '%s\n' "$out" | grep -E '^  FAIL' | head -5 | sed 's/^/    /'
  fi
done

echo
if [ -n "$failed" ]; then
  echo "run: failed:$failed"
  exit 1
fi
echo "run: every suite passed"
