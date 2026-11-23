#!/bin/sh
# E040 on the FRDM-MCXN947 board -- written here, not ported. After build_all.sh
# and run_gates.sh: this takes their kernel object, case table and header,
# builds the same driver (zephyr/) for frdm_mcxn947/mcxn947/cpu0, writes it to
# the board through LinkServer on a Linux host the board's MCU-Link (J17) is
# plugged into, and reads the board's console on that host. The kernel object
# is the one the QEMU run used, byte for byte, so comparing the two consoles is
# one compiler on two platforms of this repository, not an oracle.
#
# The host and what it needs are ../frdm-host.sh's: FRDM_HOST (unset, the lane
# does not run), FRDM_LINKSERVER, FRDM_TTY, FRDM_PROBE and FRDM_TIMEOUT.
#
# Three outcomes: exit 0 when every check passes, 1 when one fails, and 3 when
# a prerequisite is missing (NOT RUN, with the reason); REQUIRE_ALL=1 turns
# NOT RUN into a failure. A missing e040 build is exit 2, as for every lane.
#
# Writes, in $OUT/frdm/results: ran.tsv, trap.tsv and platforms.tsv (checks),
# frdm.txt, the flash logs and the serial_*.log consoles (records).
set -u
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
. "$HERE/../frdm-host.sh"
BOARD=frdm_mcxn947/mcxn947/cpu0
# Never taken from the environment; emptied only if workdir.sh made it.
FW=$OUT/frdm
FRES=$FW/results
fs_fresh_workdir "$FW"
mkdir -p "$FRES" "$FW/gen"
FRDM_LABEL=$LANE/frdm
FRDM_RES=$FRES
LC_ALL=C
export LC_ALL

# --- prerequisites ------------------------------------------------------------
for f in "$OUT/gen/kern.cortex-m33-zephyr.o" "$OUT/gen/cases.inc" \
         "$OUT/gen/spinel_freestanding.cortex-m33-zephyr.h" "$OUT/gen/expect.tsv" \
         "$RES/qemu_m33.log" "$RES/qemu_panic.log"; do
  [ -f "$f" ] || { echo "$LANE/frdm: no $f (run build_all.sh and run_gates.sh first)" >&2; exit 2; }
done
frdm_require
need_zephyr

# --- the two images -----------------------------------------------------------
# The header is the M33 one by name: build_all.sh leaves gen/spinel_freestanding.h
# as whichever profile it built last.
cp "$OUT/gen/kern.cortex-m33-zephyr.o" "$FW/gen/kern.o"
cp "$OUT/gen/cases.inc" "$FW/gen/cases.inc"
cp "$OUT/gen/spinel_freestanding.cortex-m33-zephyr.h" "$FW/gen/spinel_freestanding.h"
build_frdm() {   # $1 = tag, then extra cmake args
  tag=$1; shift
  echo "== west build $tag ($BOARD) =="
  "$WEST" build -p always -b "$BOARD" -d "$FW/build_$tag" "$HERE/zephyr" -- \
      -DSPINEL_OBJ="$FW/gen/kern.o" -DSPINEL_GEN_DIR="$FW/gen" "$@" \
      > "$FW/west_$tag.log" 2>&1 || {
    tail -20 "$FW/west_$tag.log" >&2; echo "west build $tag failed" >&2; exit 1; }
  grep -m1 -- '-- Found toolchain' "$FW/west_$tag.log" || true
}
build_frdm frdm
build_frdm frdm_panic -DE040_PANIC_TRAP=1

# --- the board ----------------------------------------------------------------
frdm_open
echo "kern.o $(frdm_sha "$FW/gen/kern.o")" >> "$FRES/frdm.txt"
for tag in frdm frdm_panic; do
  echo "== board: $tag =="
  frdm_flash "$tag" "$FW/build_$tag/zephyr/zephyr.bin"
  case $tag in
    frdm) frdm_console "$tag" 'E040	(END|FATAL)' 0 ;;
    *) frdm_console "$tag" 'E040	(TRAP|FATAL)' 2 ;;
  esac
done

# --- checks -------------------------------------------------------------------
extract() {   # stdin = console lines -> case<TAB>result
  grep '^E040	' | grep -v '	BEGIN	\|	END	\|	FATAL	' | cut -f2-
}
frdm_last_run "$FRES/serial_frdm.log" > "$FRES/run.frdm.txt"
frdm_last_run "$FRES/serial_frdm_panic.log" > "$FRES/run.frdm_panic.txt"
frdm_last_run "$RES/qemu_m33.log" > "$FRES/run.qemu.txt"
frdm_last_run "$RES/qemu_panic.log" > "$FRES/run.qemu_panic.txt"

ncases=$(( $(wc -l < "$OUT/gen/expect.tsv") - 1 ))
log=$FRES/run.frdm.txt
rows=$(extract < "$log" | sed '/^$/d' | wc -l | tr -d ' ')
end=$(grep -c '^E040	END' "$log"); fatal=$(grep -c '^E040	FATAL' "$log")
if [ "$rows" = "$ncases" ] && [ "$end" -ge 1 ] && [ "$fatal" = 0 ]; then v=PASS; else v=FAIL; fi
{
  printf 'target\tcases\trows\tend\tfatal\tverdict\n'
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$BOARD" "$ncases" "$rows" "$end" "$fatal" "$v"
} > "$FRES/ran.tsv"

# The same three rows run_gates.sh writes for QEMU.
log=$FRES/run.frdm_panic.txt
{
  printf 'check\tresult\n'
  # mulnarrow(46341, 46341) overflows the 32-bit body: code 1 (decision 0019).
  if grep -q '^E040	TRAP	code=1' "$log"; then
    printf 'panic_trap_reached\tPASS\n'
  else
    printf 'panic_trap_reached\tFAIL\n'
  fi
  if grep -q 'E040	UNREACHABLE' "$log"; then
    printf 'panic_stops_execution\tFAIL (execution continued past the trap)\n'
  else
    printf 'panic_stops_execution\tPASS\n'
  fi
  if grep -qi 'PANIC\|Halting system\|Faulting instruction' "$log"; then
    printf 'panic_reported_by_zephyr\tPASS\n'
  else
    printf 'panic_reported_by_zephyr\tFAIL\n'
  fi
} > "$FRES/trap.tsv"

verdict() { if "$@"; then echo PASS; else echo FAIL; fi; }
begin_is_board() { grep -q "^E040	BEGIN	$BOARD\$" "$1"; }
{
  printf 'check\tdetail\tverdict\n'
  for tag in frdm frdm_panic; do
    eval "rs=\$FRDM_SUM_$tag rc=\$FRDM_RC_$tag"
    ls=$(frdm_sha "$FW/build_$tag/zephyr/zephyr.bin")
    printf 'image_transferred_%s\t%s\t%s\n' "$tag" "$rs" "$(verdict [ "$rs" = "$ls" ])"
    printf 'flashed_%s\trc %s\t%s\n' "$tag" "$rc" "$(verdict frdm_flashed "$tag")"
    printf 'console_board_%s\t%s\t%s\n' "$tag" \
      "$(grep -m1 '^E040	BEGIN	' "$FRES/run.$tag.txt" | cut -f3)" \
      "$(verdict begin_is_board "$FRES/run.$tag.txt")"
  done
  extract < "$FRES/run.qemu.txt" > "$FRES/rows.qemu.tsv"
  extract < "$FRES/run.frdm.txt" > "$FRES/rows.frdm.tsv"
  n=$(wc -l < "$FRES/rows.frdm.tsv" | tr -d ' ')
  if [ "$n" -gt 0 ] && cmp -s "$FRES/rows.qemu.tsv" "$FRES/rows.frdm.tsv"; then
    printf 'rows_match_qemu\t%s rows\tPASS\n' "$n"
  else
    printf 'rows_match_qemu\t%s differing lines\tFAIL\n' \
      "$(diff "$FRES/rows.qemu.tsv" "$FRES/rows.frdm.tsv" | grep -c '^[<>]')"
  fi
  grep '^E040	TRAP	' "$FRES/run.qemu_panic.txt" > "$FRES/trap.qemu.txt"
  grep '^E040	TRAP	' "$FRES/run.frdm_panic.txt" > "$FRES/trap.frdm.txt"
  if [ -s "$FRES/trap.frdm.txt" ] && cmp -s "$FRES/trap.qemu.txt" "$FRES/trap.frdm.txt"; then
    printf 'panic_trap_matches_qemu\tidentical\tPASS\n'
  else
    printf 'panic_trap_matches_qemu\tdiffer\tFAIL\n'
  fi
} > "$FRES/platforms.tsv"

cat "$FRES/ran.tsv"; echo "---"; cat "$FRES/trap.tsv"; echo "---"; cat "$FRES/platforms.tsv"
! grep -q FAIL "$FRES/ran.tsv" "$FRES/trap.tsv" "$FRES/platforms.tsv"
