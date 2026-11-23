#!/bin/sh
#
# tools/gcmon/run_gcmon_gate.sh — the gate for DOOM's DYNAMIC zero allocation.
#
#   tools/gcmon/run_gcmon_gate.sh        # PASS 0, FAIL 1, SKIP 2
#
#   WAD      the IWAD; default build/doom-wad/doom1.wad, fetched with
#            tools/doom/fetch-iwad.sh when absent
#   SPINEL   default vendor/spinel/bin/spinel
#   CC       the C compiler Spinel and the malloc counter use (default cc)
#   TICS_A / TICS_B   default 500 / 5026
#
# What it guards. spinel-llvm showed DOOM's zero allocation two ways: statically
# (no allocation site reachable from the frame loop) and dynamically (both
# counters attached, DEMO1 run to tic 500 and to tic 5026, every count equal).
# Only the static half was a standing check; the dynamic half was measured once.
# Tests that compare output cannot see an allocation that comes back. This gate
# is that dynamic half.
#
# The subject is examples/doom/bin/bench_tic.rb in mode 1: every tic simulated
# and its frame drawn (3D view, status bar, HUD), with no output written. The
# verdict is by COUNTS: the difference between the two runs, 4526 tics of play,
# must allocate nothing. It is a comparison of this build with itself, not with
# another implementation.
#
# If a prerequisite is missing, the answer is SKIP, never PASS; an instrument
# that leaves no output is MISSING, and that fails.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
WORK="${TMPDIR:-/tmp}/spinel-gcmon-gate"
SPINEL="${SPINEL:-$ROOT/vendor/spinel/bin/spinel}"
CC="${CC:-cc}"
TICS_A="${TICS_A:-500}"
TICS_B="${TICS_B:-5026}"

case "$(uname -s)" in
  Darwin) ;;
  *) echo "---- gcmon gate: SKIP (the malloc counter is DYLD interposition, macOS only)"; exit 2 ;;
esac

if [ ! -x "$SPINEL" ]; then
  echo "---- gcmon gate: SKIP (no $SPINEL; build vendor/spinel first)"
  exit 2
fi

WAD="${WAD:-$ROOT/build/doom-wad/doom1.wad}"
if [ ! -f "$WAD" ]; then
  "$ROOT/tools/doom/fetch-iwad.sh" "$(dirname -- "$WAD")" >/dev/null 2>&1 || true
fi
if [ ! -f "$WAD" ]; then
  echo "---- gcmon gate: SKIP (no IWAD at $WAD; a missing prerequisite is not a PASS)"
  exit 2
fi

# Rebuilt every time: a stale binary from another pin must not answer.
mkdir -p "$WORK"
BIN="$WORK/bench_tic"
rm -f "$BIN"
echo "== building bench_tic"
if ! "$SPINEL" "$ROOT/examples/doom/bin/bench_tic.rb" --cc="$CC" -o "$BIN" >"$WORK/build.log" 2>&1; then
  cat "$WORK/build.log"
  echo "---- gcmon gate: FAIL (bench_tic does not build)"
  exit 1
fi

echo "== doom: zero allocation (DEMO1 tic $TICS_A vs $TICS_B, mode=1)"
rc=0
ruby "$HERE/spinel-gcmon" ab \
  --a "$BIN $WAD DEMO1 $TICS_A 1" \
  --b "$BIN $WAD DEMO1 $TICS_B 1" \
  --expect-zero || rc=$?

# spinel-gcmon exits 2 when it could not measure at all; past the checks above
# that is a failure of the gate, not a skip.
if [ "$rc" = 0 ]; then
  echo "---- gcmon gate: PASS"
  exit 0
fi
echo "---- gcmon gate: FAIL (spinel-gcmon exit $rc)"
exit 1
