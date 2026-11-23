#!/usr/bin/env bash
# E081 gates -- the four-way differential over the platform-extern kernel, the
# trap probes at the NEW trap site (extern-argument narrowing), and the
# device-only property rows.
#
#   bash build_all.sh && bash run_gates.sh
#
# Produces, all in this directory:
#   gates.tsv     one row per case: expect / native / m33 / rv32 / wasm32 / verdict
#   trap.tsv      wasm trap semantics + the panic-build evidence
#   zephyr.tsv    the platform-property rows (uptime, sleep, gpio backend, print)
#   qemu_*.log    the raw device consoles
set -euo pipefail
# Kept as an oracle; it runs only on the owner's instruction (tools/oracle/gate).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)/tools/oracle/gate" tests/freestanding/e081/oracle/run_gates.sh whole || exit 0

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd -- "$HERE/../../../.." && pwd)
SCRATCH=${SCRATCH:-/tmp/spinel-llvm-scratch/session-b}
OUT=${OUT:-$SCRATCH/e081/work}
WEST=${WEST:-west}
export ZEPHYR_BASE="${ZEPHYR_BASE:-$HOME/sdk/zephyrproject/zephyr}"
export ZEPHYR_SDK_INSTALL_DIR="${ZEPHYR_SDK_INSTALL_DIR:-$HOME/zephyr-sdk-1.0.1}"
export ZEPHYR_TOOLCHAIN_VARIANT="${ZEPHYR_TOOLCHAIN_VARIANT:-zephyr}"
NO_DEVICE=${NO_DEVICE:-0}

mkdir -p "$OUT/logs"

# --- 1. native (one process per case: mix_div0 raises) --------------------
: > "$OUT/logs/native.tsv"
n=$(( $(wc -l < "$HERE/expect.tsv") - 1 ))
i=0
while [ "$i" -lt "$n" ]; do
  name=$(awk -F'\t' -v i="$i" '$1==i{print $2}' "$HERE/expect.tsv")
  if o=$(cd "$OUT/host" && ./e081_host "$i" 2>&1); then
    printf '%s\n' "$o" | head -1 >> "$OUT/logs/native.tsv"
  else
    printf '%s\traise:%s\n' "$name" "$(printf '%s' "$o" | head -1)" >> "$OUT/logs/native.tsv"
  fi
  i=$(( i + 1 ))
done

# --- 2. wasm32 (node) -----------------------------------------------------
node "$HERE/run_node.mjs" "$OUT/gen/kern.wasm" "$OUT/gen/cases.json" \
  > "$OUT/logs/wasm32.raw"
grep -v '	PROP	' "$OUT/logs/wasm32.raw" | sed 's/^E081	//' > "$OUT/logs/wasm32.tsv"

# --- 3. the two QEMU boards (E067/E077's stop-on-terminator shape) --------
extract() { grep '^E081	' "$1" | grep -v '	BEGIN	\|	END	\|	FATAL	\|	PROP	' | cut -f2- | tr -d '\r'; }
run_qemu() {   # $1 = build tag, $2 = log, $3 = terminator regex
  local tag=$1 log=$2 term=$3
  rm -f "$OUT/build_$tag/qemu.pid"
  ( "$WEST" build -d "$OUT/build_$tag" -t run > "$HERE/$log" 2>&1 ) &
  local wpid=$!
  local i=0
  while [ $i -lt 300 ]; do
    grep -qE "$term" "$HERE/$log" 2>/dev/null && break
    sleep 1; i=$(( i + 1 ))
  done
  if [ -f "$OUT/build_$tag/qemu.pid" ]; then
    kill "$(cat "$OUT/build_$tag/qemu.pid")" 2>/dev/null || true
  fi
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  rm -f "$OUT/build_$tag/qemu.pid"
}
if [ "$NO_DEVICE" != 1 ]; then
  run_qemu m33      qemu_m33.log   'E081	END'
  run_qemu riscv32  qemu_rv32.log  'E081	END'
  run_qemu m33panic qemu_panic.log 'PANIC|Halting|Faulting instruction'
  extract "$HERE/qemu_m33.log"  > "$OUT/logs/m33.tsv"
  extract "$HERE/qemu_rv32.log" > "$OUT/logs/rv32.tsv"
fi

# --- 4. the join ----------------------------------------------------------
python3 "$HERE/compare.py" "$HERE/expect.tsv" \
  native="$OUT/logs/native.tsv" m33="$OUT/logs/m33.tsv" \
  rv32="$OUT/logs/rv32.tsv" wasm32="$OUT/logs/wasm32.tsv" > "$HERE/gates.tsv"
tail -3 "$HERE/gates.tsv"
grep -q 'fail=0' "$HERE/gates.tsv" || { echo "gates.tsv has failures" >&2; exit 1; }

# --- 5. traps at the NEW site (extern-argument narrowing) -----------------
{
  node "$HERE/trap_probe.mjs" "$OUT/gen/kern.wasm" || true
  chk() { # id, condition, note
    if eval "$2"; then printf 'PASS\t%s\t%s\n' "$1" "$3"
    else printf 'FAIL\t%s\t%s\n' "$1" "$3"; fi
  }
  chk panic_trap_reached \
    "grep -q 'E081	TRAP	code=3' '$HERE/qemu_panic.log'" \
    "the panic build reached trap code 3 (argument 1 of gpio_set does not fit i32)"
  chk panic_no_resume \
    "! grep -q 'E081	UNREACHABLE' '$HERE/qemu_panic.log'" \
    "no line after the trap was executed"
  chk panic_reported \
    "grep -qiE 'PANIC|Halting system|Faulting instruction' '$HERE/qemu_panic.log'" \
    "Zephyr reported the panic"
} > "$HERE/trap.tsv"
cat "$HERE/trap.tsv"
if grep -q '^FAIL' "$HERE/trap.tsv"; then echo "trap.tsv has failures" >&2; exit 1; fi

# --- 6. the platform-property rows ----------------------------------------
{
  printf 'leg\tprop\tvalue\tverdict\n'
  prop() {  # leg, log, prop, expect-regex
    local leg=$1 log=$2 p=$3 want=$4
    local v
    v=$(grep "	PROP	$p	" "$log" | head -1 | awk -F'\t' '{print $NF}' | tr -d '\r')
    if printf '%s' "$v" | grep -qE "$want"; then
      printf '%s\t%s\t%s\tPASS\n' "$leg" "$p" "$v"
    else
      printf '%s\t%s\t%s\tFAIL (want %s)\n' "$leg" "$p" "${v:--}" "$want"
    fi
  }
  prop m33  "$HERE/qemu_m33.log" uptime_monotonic '^1$'
  prop m33  "$HERE/qemu_m33.log" sleep_elapsed    '^1$'
  prop m33  "$HERE/qemu_m33.log" gpio_backend     '^real_pins=2$'
  prop m33  "$HERE/qemu_m33.log" gpio_readback    '^1$'
  prop m33  "$HERE/qemu_m33.log" gpio_readback0   '^0$'
  prop rv32 "$HERE/qemu_rv32.log" uptime_monotonic '^1$'
  prop rv32 "$HERE/qemu_rv32.log" sleep_elapsed    '^1$'
  prop rv32 "$HERE/qemu_rv32.log" gpio_backend     '^real_pins=0$'
  prop rv32 "$HERE/qemu_rv32.log" gpio_readback    '^1$'
  # the print side effect: the chirp case printed exactly one E081P line
  for leg in m33 rv32; do
    log="$HERE/qemu_m33.log"; [ "$leg" = rv32 ] && log="$HERE/qemu_rv32.log"
    c=$(grep -c '^E081P	print	4223' "$log" || true)
    if [ "$c" = 1 ]; then printf '%s\tprint_witness\t%s\tPASS\n' "$leg" "$c"
    else printf '%s\tprint_witness\t%s\tFAIL (want 1)\n' "$leg" "$c"; fi
  done
  prop wasm32 "$OUT/logs/wasm32.raw" print_witness '^1$'
} > "$HERE/zephyr.tsv"
cat "$HERE/zephyr.tsv"
if grep -q 'FAIL' "$HERE/zephyr.tsv"; then echo "zephyr.tsv has failures" >&2; exit 1; fi
echo "run_gates: done"
