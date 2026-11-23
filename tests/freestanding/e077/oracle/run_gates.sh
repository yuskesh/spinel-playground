#!/usr/bin/env bash
# E077 gates -- the four-way differential, the trap probes, the sizes.
#
#   bash build_all.sh && bash run_gates.sh
#
# Produces, all in this directory:
#   gates.tsv     one row per case: expect / native / m33 / rv32 / wasm32 / verdict
#   trap.tsv      the broken shapes a buffer boundary can be handed at RUN time
#   qemu_*.log    the raw device consoles
set -euo pipefail
# Kept as an oracle; it runs only on the owner's instruction (tools/oracle/gate).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)/tools/oracle/gate" tests/freestanding/e077/oracle/run_gates.sh whole || exit 0

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd -- "$HERE/../../../.." && pwd)
SCRATCH=${SCRATCH:-/tmp/spinel-llvm-scratch/session-a}
OUT=${OUT:-$SCRATCH/e077/work}
WEST=${WEST:-west}
export ZEPHYR_BASE="${ZEPHYR_BASE:-$HOME/sdk/zephyrproject/zephyr}"
export ZEPHYR_SDK_INSTALL_DIR="${ZEPHYR_SDK_INSTALL_DIR:-$HOME/zephyr-sdk-1.0.1}"
export ZEPHYR_TOOLCHAIN_VARIANT="${ZEPHYR_TOOLCHAIN_VARIANT:-zephyr}"
NO_DEVICE=${NO_DEVICE:-0}

mkdir -p "$OUT/logs"

# --- 1. native ------------------------------------------------------------
# One process per case, because a case that raises takes the process with it
# (E040 made the same choice for the same reason).
: > "$OUT/logs/native.tsv"
n=$(( $(wc -l < "$HERE/expect.tsv") - 1 ))
i=0
while [ "$i" -lt "$n" ]; do
  name=$(awk -F'\t' -v i="$i" '$1==i{print $2}' "$HERE/expect.tsv")
  if o=$(cd "$OUT/host" && ./e077_host "$i" 2>&1); then
    printf '%s\n' "$o" | head -1 >> "$OUT/logs/native.tsv"
  else
    printf '%s\traise:%s\n' "$name" "$(printf '%s' "$o" | head -1)" >> "$OUT/logs/native.tsv"
  fi
  i=$(( i + 1 ))
done

# --- 2. wasm32 (node) -----------------------------------------------------
node "$HERE/run_node.mjs" "$OUT/gen/kern.wasm" "$OUT/gen/cases.json" \
  | sed 's/^E077\t//' > "$OUT/logs/wasm32.tsv"

# --- 3. the two QEMU boards ----------------------------------------------
extract() { grep '^E077	' "$1" | grep -v '	BEGIN	\|	END	\|	FATAL	' | cut -f2- | tr -d '\r'; }
# A Zephyr image does not exit -- main() returns and the kernel idles -- so the
# run has to be STOPPED once the terminator appears.  Waiting out a timeout
# instead costs five minutes per board and, worse, makes a genuine hang look
# exactly like a healthy run.  E067 learned the same thing and also learned that
# killing `west` is not enough: QEMU is a grandchild, and a survivor leaves a
# stale <build>/qemu.pid that makes the NEXT run fail to start.
run_qemu() {   # $1 = build tag, $2 = log, $3 = terminator regex
  local tag=$1 log=$2 term=$3
  # A survivor from a previous (killed) run leaves this behind and the next
  # QEMU refuses to start with "cannot create PID file".  Measured, twice.
  rm -f "$OUT/build_$tag/qemu.pid"
  ( "$WEST" build -d "$OUT/build_$tag" -t run > "$HERE/$log" 2>&1 ) &
  local wpid=$!
  local i=0
  while [ $i -lt 300 ]; do
    grep -qE "$term" "$HERE/$log" 2>/dev/null && break
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
  # The panic build never prints END -- that is the point of it -- so it is
  # stopped on whatever Zephyr says when the world stops.
  run_qemu m33panic qemu_panic.log 'PANIC|Halting|Faulting instruction'
  extract "$HERE/qemu_m33.log"  > "$OUT/logs/m33.tsv"
  extract "$HERE/qemu_rv32.log" > "$OUT/logs/rv32.tsv"
else
  : > "$OUT/logs/m33.tsv"; : > "$OUT/logs/rv32.tsv"
fi

# --- 4. the join ----------------------------------------------------------
python3 "$HERE/compare.py" "$HERE/expect.tsv" \
    native="$OUT/logs/native.tsv" m33="$OUT/logs/m33.tsv" \
    rv32="$OUT/logs/rv32.tsv" wasm32="$OUT/logs/wasm32.tsv" \
    > "$HERE/gates.tsv" || true
tail -1 "$HERE/gates.tsv"

# --- 5. the broken shapes, at RUN time ------------------------------------
# The compile-time half of "what a buffer boundary refuses" is run_reject.sh.
# This is the other half: shapes that only exist once a caller exists.
node "$HERE/trap_probe.mjs" "$OUT/gen/kern.wasm" > "$HERE/trap.tsv"
if [ "$NO_DEVICE" != 1 ]; then
  {
    grep -q '^E077	TRAP	code=4' "$HERE/qemu_panic.log" \
      && echo "PASS	device_bounds_trap_reached	code=4 on mps2/an521" \
      || echo "FAIL	device_bounds_trap_reached	-"
    grep -q 'E077	UNREACHABLE' "$HERE/qemu_panic.log" \
      && echo "FAIL	device_trap_stops_execution	the line after the trap ran" \
      || echo "PASS	device_trap_stops_execution	nothing after the trap ran"
    grep -qi 'PANIC\|Halting system\|Faulting instruction' "$HERE/qemu_panic.log" \
      && echo "PASS	device_panic_reported	zephyr reported the fault" \
      || echo "FAIL	device_panic_reported	-"
  } >> "$HERE/trap.tsv"
fi
column -t -s$'\t' "$HERE/trap.tsv" 2>/dev/null || cat "$HERE/trap.tsv"

echo "run_gates: done"
