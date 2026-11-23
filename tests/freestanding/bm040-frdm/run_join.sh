#!/usr/bin/env bash
# bm040-frdm against bm040: one kernel, the same driver, two machines -- QEMU's
# mps2-an521 and the FRDM-MCXN947 board. After run_gates.sh here and bm040's
# build_all.sh and run_gates.sh in the same $FS_WORK (run.sh runs bm040
# first). This is not an oracle: both sides are this repository's compiler and
# driver.
#
# Writes $RES/platforms.tsv:
#   same_kernel_object  this lane's kern.o and bm040's are byte-identical (the
#                       same profile);
#   rows_match_qemu     every case line, BEGIN and END aside, is the same as
#                       bm040's QEMU run;
#   panic_trap_matches_qemu  the panic image's TRAP line is the same.
# Exits 3 (NOT RUN) when run_gates.sh did not reach the board, or 1 under
# REQUIRE_ALL=1.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
. "$HERE/../frdm-host.sh"
FRDM_LABEL=$LANE
FRDM_RES=$RES
BM040_OUT=${FS_WORK:-${TMPDIR:-/tmp}/spinel-freestanding}/bm040
qlog="$BM040_OUT/results/qemu_bm.log"
qpanic="$BM040_OUT/results/qemu_panic.log"
qobj="$BM040_OUT/gen/kern.o"
for f in "$qlog" "$qpanic" "$qobj" "$OUT/gen/kern.o"; do
  [ -f "$f" ] || { echo "$LANE: no $f (run bm040 and this lane's build_all.sh first)" >&2; exit 2; }
done
rm -f "$RES/platforms.tsv"
[ -f "$RES/run.bm.txt" ] && [ -f "$RES/run.bm_panic.txt" ] ||
  frdm_not_run "the board did not run (run_gates.sh: $(cat "$RES/not_run.txt" 2>/dev/null || echo 'no console'))"

extract() {  # stdin = console lines -> case<TAB>result
  grep '^E040	' | grep -v '	BEGIN	\|	END	\|	FATAL	' | cut -f2-
}
frdm_last_run "$qlog" | extract > "$RES/rows.qemu.tsv"
extract < "$RES/run.bm.txt" > "$RES/rows.board.tsv"
frdm_last_run "$qpanic" | grep '^E040	TRAP	' > "$RES/trap.qemu.txt"
grep '^E040	TRAP	' "$RES/run.bm_panic.txt" > "$RES/trap.board.txt"
{
printf 'check\tdetail\tverdict\n'
if cmp -s "$OUT/gen/kern.o" "$qobj"; then v=PASS; d=identical; else v=FAIL; d=differ; fi
printf 'same_kernel_object\t%s\t%s\n' "$d" "$v"
n=$(wc -l < "$RES/rows.board.tsv" | tr -d ' ')
if [ "$n" -gt 0 ] && cmp -s "$RES/rows.qemu.tsv" "$RES/rows.board.tsv"; then
  v=PASS; d="$n rows"
else
  v=FAIL; d="$(diff "$RES/rows.qemu.tsv" "$RES/rows.board.tsv" | grep -c '^[<>]') differing lines"
fi
printf 'rows_match_qemu\t%s\t%s\n' "$d" "$v"
if [ -s "$RES/trap.board.txt" ] && cmp -s "$RES/trap.qemu.txt" "$RES/trap.board.txt"; then
  v=PASS; d=identical
else
  v=FAIL; d=differ
fi
printf 'panic_trap_matches_qemu\t%s\t%s\n' "$d" "$v"
} > "$RES/platforms.tsv"
cat "$RES/platforms.tsv"
! grep -q FAIL "$RES/platforms.tsv"
