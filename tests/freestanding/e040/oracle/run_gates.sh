#!/usr/bin/env bash
# E040 measurements.  build_all.sh first.
#
# CORRECTNESS AND SIZE ONLY.  The verification rules of the predecessor's plan forbid timing anything on an
# MCU (a QEMU second is not a second), so nothing here is timed and no
# performance claim is made anywhere in E040.  Code size IS measured, because
# `llvm-size` on a cross object and Zephyr's own FLASH accounting are both exact.
#
#   gates.tsv        the differential oracle: host (i64, C back end) vs MCU
#   qemu_m33.log     raw QEMU output, Cortex-M33
#   qemu_riscv32.log raw QEMU output, RV32
#   qemu_panic.log   the k_panic() trap platform (the trap really is fatal)
#   size.tsv         per-function and per-object sizes, both targets
#   undef_*.tsv      the undefined-symbol gate's verdicts (written by build_all)
set -uo pipefail
# Kept as an oracle; it runs only on the owner's instruction (tools/oracle/gate).
"$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)/tools/oracle/gate" tests/freestanding/e040/oracle/run_gates.sh whole || exit 0

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd -- "$HERE/../../../.." && pwd)
SCRATCH=${SCRATCH:-/tmp/spinel-llvm-scratch/session-a}
OUT=${OUT:-$SCRATCH/e040/work}
LLVM_PREFIX=${LLVM_PREFIX:-/opt/homebrew/opt/llvm}
NM="$LLVM_PREFIX/bin/llvm-nm"
SIZE="$LLVM_PREFIX/bin/llvm-size"

export ZEPHYR_BASE="${ZEPHYR_BASE:-$HOME/sdk/zephyrproject/zephyr}"
export ZEPHYR_SDK_INSTALL_DIR="${ZEPHYR_SDK_INSTALL_DIR:-$HOME/zephyr-sdk-1.0.1}"
export ZEPHYR_TOOLCHAIN_VARIANT="${ZEPHYR_TOOLCHAIN_VARIANT:-zephyr}"
WEST=${WEST:-west}

# --- 1. the host side ------------------------------------------------------
# One process per case: `qdiv(1, 0)` raises and would otherwise swallow the rows
# after it.  A raise is recorded as `raise:<message>`, which can never compare
# equal to an MCU value -- that is the point.
echo "== host oracle =="
: > "$OUT/host.tsv"
n=$(($(wc -l < "$HERE/expect.tsv") - 1))
i=0
while [ "$i" -lt "$n" ]; do
  o=$(cd "$OUT/host" && ./e040_host "$i" 2>&1)
  rc=$?
  name=$(awk -F'\t' -v i="$i" '$1==i{print $2}' "$HERE/expect.tsv")
  if [ "$rc" -ne 0 ]; then
    printf '%s\traise:%s\n' "$name" "$(echo "$o" | head -1)" >> "$OUT/host.tsv"
  else
    echo "$o" | head -1 >> "$OUT/host.tsv"
  fi
  i=$((i + 1))
done

# --- 2. the MCU side -------------------------------------------------------
run_qemu() {   # $1 = build tag, $2 = log name
  echo "== qemu: $1 =="
  timeout 180 "$WEST" build -d "$OUT/build_$1" -t run > "$HERE/$2" 2>&1
  grep -c '^E040' "$HERE/$2" > /dev/null || echo "  (no E040 lines in $2)"
}
run_qemu m33      qemu_m33.log
run_qemu riscv32  qemu_riscv32.log
run_qemu m33panic qemu_panic.log

# QEMU's serial console emits CRLF, so the trailing \r has to go or every
# comparison against the host's LF-terminated output fails.
extract() {  # $1 = log -> two-column TSV of case/result
  grep '^E040	' "$1" | grep -v '	BEGIN	\|	END	\|	FATAL	' | cut -f2- | tr -d '\r'
}

# --- 3. the join -----------------------------------------------------------
{
printf 'target\tidx\tcase\texpect\thost\tmcu\tverdict\n'
for t in m33 riscv32; do
  log="$HERE/qemu_$t.log"
  extract "$log" > "$OUT/mcu.$t.tsv"
  tail -n +2 "$HERE/expect.tsv" | while IFS=$'\t' read -r idx name expect; do
    h=$(awk -F'\t' -v n="$name" '$1==n{print $2; exit}' "$OUT/host.tsv")
    m=$(awk -F'\t' -v n="$name" '$1==n{print $2; exit}' "$OUT/mcu.$t.tsv")
    if [ -z "$m" ]; then
      v=MISSING
    elif [ "$expect" = same ]; then
      [ "$h" = "$m" ] && v=PASS || v=FAIL
    else
      [ "$h" != "$m" ] && v=PASS || v=FAIL
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$t" "$idx" "$name" "$expect" "$h" "$m" "$v"
  done
done
} > "$HERE/gates.tsv"

# --- 4. the trap platform --------------------------------------------------
# The harness build's spinel_trap longjmps so that all cases fit in one image.
# This build's spinel_trap does what a product would do, and the run has to STOP.
{
printf 'check\tresult\n'
if grep -q '^E040	TRAP	code=3' "$HERE/qemu_panic.log"; then
  printf 'panic_trap_reached\tPASS\n'
else
  printf 'panic_trap_reached\tFAIL\n'
fi
if grep -q 'E040	UNREACHABLE' "$HERE/qemu_panic.log"; then
  printf 'panic_stops_execution\tFAIL (execution continued past the trap)\n'
else
  printf 'panic_stops_execution\tPASS\n'
fi
if grep -qi 'PANIC\|Halting system\|Faulting instruction' "$HERE/qemu_panic.log"; then
  printf 'panic_reported_by_zephyr\tPASS\n'
else
  printf 'panic_reported_by_zephyr\tFAIL\n'
fi
} > "$HERE/trap.tsv"

# --- 5. size ---------------------------------------------------------------
# P003 lets us claim size and only size.  Two granularities: the whole object,
# and each exported boundary (the wrappers are what E040 added, so their cost is
# the interesting number).
{
printf 'target\tkind\tname\tbytes\n'
for t in cortex-m33-zephyr riscv32-zephyr; do
  o="$OUT/gen/kern.$t.o"
  printf '%s\tobject\ttext\t%s\n' "$t" "$($SIZE "$o" | awk 'NR==2{print $1}')"
  # BSD awk has no strtonum, and llvm-nm prints the size in hex.
  "$NM" --print-size --defined-only "$o" \
    | python3 -c 'import sys
for l in sys.stdin:
    f = l.split()
    if len(f) >= 4 and f[2] in ("T", "t"):
        print("%s\tfunction\t%s\t%d" % ("'"$t"'", f[3], int(f[1], 16)))'
done
} > "$HERE/size.tsv"

# Zephyr's own accounting, from the build logs the images were produced with.
{
printf 'image\tregion\tbytes\n'
for b in m33 m33panic riscv32; do
  if [ -f "$OUT/build_$b/zephyr/zephyr.elf" ]; then
    $SIZE "$OUT/build_$b/zephyr/zephyr.elf" \
      | awk -v b="$b" 'NR==2{printf "%s\ttext\t%s\n%s\tdata\t%s\n%s\tbss\t%s\n", b,$1,b,$2,b,$3}'
  fi
done
} >> "$HERE/size.tsv"

# --- 6. summary ------------------------------------------------------------
echo
awk -F'\t' 'NR>1{c[$7]++} END{for (k in c) printf "%s %d\n", k, c[k]}' "$HERE/gates.tsv"
echo "---"
cat "$HERE/trap.tsv"
echo "---"
fails=$(awk -F'\t' 'NR>1 && $7!="PASS"' "$HERE/gates.tsv" | wc -l | tr -d ' ')
tfails=$(grep -c FAIL "$HERE/trap.tsv" || true)
echo "gates.tsv: $(($(wc -l < "$HERE/gates.tsv") - 1)) rows, $fails not PASS"
[ "$fails" = 0 ] && [ "$tfails" = 0 ]
