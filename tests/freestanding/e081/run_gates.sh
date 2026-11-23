#!/usr/bin/env bash
# E081 gates -- the device runs of the platform-extern kernel, the trap probes
# at the NEW trap site (extern-argument narrowing), and the device-only
# property rows. Ported from spinel-llvm 463d49dd
# docs/experiments/results/E081/run_gates.sh.
#
# Not run here: the four-way differential (native / m33 / rv32 / wasm32 joined
# against the host build by compare.py). It compares with another
# implementation's behaviour, so it is an oracle and runs only on the user's
# instruction; the original is kept in oracle/. What replaces the join here is
# only a COUNT: each target printed one result row per case of cases.json and
# reached its END marker without a FATAL line -- that the run completed, not
# what it computed.
#
#   bash build_all.sh && bash run_gates.sh
#
# Writes, in $RES:
#   ran.tsv       one row per target: every case printed, END reached
#   trap.tsv      wasm trap semantics + the panic-build evidence
#   zephyr.tsv    the platform-property rows (uptime, sleep, gpio backend, print)
#   qemu_*.log    the raw device consoles
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
  > "$OUT/logs/wasm32.raw"
grep -v '	PROP	' "$OUT/logs/wasm32.raw" | sed 's/^E081	//' > "$OUT/logs/wasm32.tsv"

# --- 3. the two QEMU boards (E067/E077's stop-on-terminator shape) --------
extract() { grep '^E081	' "$1" | grep -v '	BEGIN	\|	END	\|	FATAL	\|	PROP	' | cut -f2- | tr -d '\r'; }
run_qemu() {   # $1 = build tag, $2 = log, $3 = terminator regex
  local tag=$1 log=$2 term=$3
  rm -f "$OUT/build_$tag/qemu.pid"
  ( "$WEST" build -d "$OUT/build_$tag" -t run > "$RES/$log" 2>&1 ) &
  local wpid=$!
  local i=0
  while [ $i -lt "$QEMU_TIMEOUT" ]; do
    grep -qE "$term" "$RES/$log" 2>/dev/null && break
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
      end=$(grep -c '^E081	END' "$3" || true); fatal=$(grep -c '^E081	FATAL' "$3" || true)
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

# --- 5. traps at the NEW site (extern-argument narrowing) -----------------
{
  "$NODE" "$HERE/trap_probe.mjs" "$OUT/gen/kern.wasm" || true
  chk() { # id, condition, note
    if eval "$2"; then printf 'PASS\t%s\t%s\n' "$1" "$3"
    else printf 'FAIL\t%s\t%s\n' "$1" "$3"; fi
  }
  if [ "$NO_DEVICE" != 1 ]; then
  chk panic_trap_reached \
    "grep -q 'E081	TRAP	code=3' '$RES/qemu_panic.log'" \
    "the panic build reached trap code 3 (argument 1 of gpio_set does not fit i32)"
  chk panic_no_resume \
    "! grep -q 'E081	UNREACHABLE' '$RES/qemu_panic.log'" \
    "no line after the trap was executed"
  chk panic_reported \
    "grep -qiE 'PANIC|Halting system|Faulting instruction' '$RES/qemu_panic.log'" \
    "Zephyr reported the panic"
  fi
} > "$RES/trap.tsv"
cat "$RES/trap.tsv"

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
  if [ "$NO_DEVICE" != 1 ]; then
  prop m33  "$RES/qemu_m33.log" uptime_monotonic '^1$'
  prop m33  "$RES/qemu_m33.log" sleep_elapsed    '^1$'
  prop m33  "$RES/qemu_m33.log" gpio_backend     '^real_pins=2$'
  prop m33  "$RES/qemu_m33.log" gpio_readback    '^1$'
  prop m33  "$RES/qemu_m33.log" gpio_readback0   '^0$'
  prop rv32 "$RES/qemu_rv32.log" uptime_monotonic '^1$'
  prop rv32 "$RES/qemu_rv32.log" sleep_elapsed    '^1$'
  prop rv32 "$RES/qemu_rv32.log" gpio_backend     '^real_pins=0$'
  prop rv32 "$RES/qemu_rv32.log" gpio_readback    '^1$'
  # the print side effect: the chirp case printed exactly one E081P line
  for leg in m33 rv32; do
    log="$RES/qemu_m33.log"; [ "$leg" = rv32 ] && log="$RES/qemu_rv32.log"
    c=$(grep -c '^E081P	print	4223' "$log" || true)
    if [ "$c" = 1 ]; then printf '%s\tprint_witness\t%s\tPASS\n' "$leg" "$c"
    else printf '%s\tprint_witness\t%s\tFAIL (want 1)\n' "$leg" "$c"; fi
  done
  fi
  prop wasm32 "$OUT/logs/wasm32.raw" print_witness '^1$'
} > "$RES/zephyr.tsv"
cat "$RES/zephyr.tsv"

bad=0
grep -q 'FAIL' "$RES/ran.tsv"    && { echo "ran.tsv has failures" >&2; bad=1; }
grep -q '^FAIL' "$RES/trap.tsv"  && { echo "trap.tsv has failures" >&2; bad=1; }
grep -q 'FAIL' "$RES/zephyr.tsv" && { echo "zephyr.tsv has failures" >&2; bad=1; }
[ "$bad" = 0 ] || exit 1
echo "run_gates: done"
