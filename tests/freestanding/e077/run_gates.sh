#!/usr/bin/env bash
# E077 gates -- the device and wasm32 runs of the Float/buffer kernel and the
# broken shapes at run time. Ported from spinel-llvm 463d49dd
# docs/experiments/results/E077/run_gates.sh.
#
# Not run here: the four-way join (native / m33 / rv32 / wasm32 against the host
# build, compare.py). It is an oracle and runs only on the user's instruction;
# the original is in oracle/. What replaces it is a COUNT: each target printed
# one row per case of cases.json and reached END without FATAL.
#
# Writes, in $RES: ran.tsv, trap.tsv and the qemu_*.log consoles.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
need_zephyr
need_wasm
NO_DEVICE=${NO_DEVICE:-0}
QEMU_TIMEOUT=${QEMU_TIMEOUT:-300}
mkdir -p "$OUT/logs" "$RES"
ncases=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["cases"].size' "$HERE/cases.json")

# --- 2. wasm32 (node) -----------------------------------------------------
"$NODE" "$HERE/run_node.mjs" "$OUT/gen/kern.wasm" "$OUT/gen/cases.json" \
  | sed 's/^E077	//' > "$OUT/logs/wasm32.tsv"

# --- 3. the two QEMU boards ----------------------------------------------
extract() { grep '^E077	' "$1" | grep -v '	BEGIN	\|	END	\|	FATAL	' | cut -f2- | tr -d '\r'; }
# A Zephyr image does not exit, so the run is STOPPED once the terminator
# appears; QEMU is a grandchild of west, and a survivor's stale qemu.pid stops
# the next run from starting, so both are killed and the pid file removed.
run_qemu() {   # $1 = build tag, $2 = log, $3 = terminator regex
  local tag=$1 log=$2 term=$3
  rm -f "$OUT/build_$tag/qemu.pid"
  ( "$WEST" build -d "$OUT/build_$tag" -t run > "$RES/$log" 2>&1 ) &
  local wpid=$!
  local i=0
  while [ $i -lt "$QEMU_TIMEOUT" ]; do
    grep -qE "$term" "$RES/$log" 2>/dev/null && break
    kill -0 "$wpid" 2>/dev/null || break
    sleep 1; i=$(( i + 1 ))
  done
  if [ -f "$OUT/build_$tag/qemu.pid" ]; then
    kill "$(cat "$OUT/build_$tag/qemu.pid")" 2>/dev/null || true
  fi
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  rm -f "$OUT/build_$tag/qemu.pid"
  return 0
}
if [ "$NO_DEVICE" != 1 ]; then
  run_qemu m33      qemu_m33.log   'E077	END'
  run_qemu riscv32  qemu_rv32.log  'E077	END'
  # The panic build never prints END -- that is the point of it.
  run_qemu m33panic qemu_panic.log 'PANIC|Halting|Faulting instruction'
  extract "$RES/qemu_m33.log"  > "$OUT/logs/m33.tsv"
  extract "$RES/qemu_rv32.log" > "$OUT/logs/rv32.tsv"
fi

# --- 4. the runs completed (a count; the value join is the oracle) --------
{
  printf 'target\tcases\trows\tend\tfatal\tverdict\n'
  ran() {  # target, rows-file, raw-console-or-empty
    local t=$1 rows end fatal v
    rows=$(sed '/^$/d' "$2" | wc -l | tr -d ' ')
    if [ -n "$3" ]; then
      end=$(grep -c '^E077	END' "$3" || true); fatal=$(grep -c '^E077	FATAL' "$3" || true)
    else end=-; fatal=0; fi
    if [ "$rows" = "$ncases" ] && [ "$fatal" = 0 ] && { [ "$end" = - ] || [ "$end" -ge 1 ]; }; then v=PASS; else v=FAIL; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$t" "$ncases" "$rows" "$end" "$fatal" "$v"
  }
  ran wasm32 "$OUT/logs/wasm32.tsv" ""
  if [ "$NO_DEVICE" != 1 ]; then
    ran m33  "$OUT/logs/m33.tsv"  "$RES/qemu_m33.log"
    ran rv32 "$OUT/logs/rv32.tsv" "$RES/qemu_rv32.log"
  fi
} > "$RES/ran.tsv"
cat "$RES/ran.tsv"

# --- 5. the broken shapes, at RUN time ------------------------------------
# The compile-time half of "what a buffer boundary refuses" is run_reject.sh.
"$NODE" "$HERE/trap_probe.mjs" "$OUT/gen/kern.wasm" > "$RES/trap.tsv"
if [ "$NO_DEVICE" != 1 ]; then
  {
    grep -q '^E077	TRAP	code=4' "$RES/qemu_panic.log" \
      && echo "PASS	device_bounds_trap_reached	code=4 on mps2/an521" \
      || echo "FAIL	device_bounds_trap_reached	-"
    grep -q 'E077	UNREACHABLE' "$RES/qemu_panic.log" \
      && echo "FAIL	device_trap_stops_execution	the line after the trap ran" \
      || echo "PASS	device_trap_stops_execution	nothing after the trap ran"
    grep -qi 'PANIC\|Halting system\|Faulting instruction' "$RES/qemu_panic.log" \
      && echo "PASS	device_panic_reported	zephyr reported the fault" \
      || echo "FAIL	device_panic_reported	-"
  } >> "$RES/trap.tsv"
fi
cat "$RES/trap.tsv"

bad=0
grep -q 'FAIL' "$RES/ran.tsv"   && { echo "ran.tsv has failures" >&2; bad=1; }
grep -q '^FAIL' "$RES/trap.tsv" && { echo "trap.tsv has failures" >&2; bad=1; }
[ "$bad" = 0 ] || exit 1
echo "run_gates: done"
