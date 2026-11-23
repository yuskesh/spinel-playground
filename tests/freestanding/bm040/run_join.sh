#!/usr/bin/env bash
# bm040 against e040: one kernel, two platforms of this repository. After
# run_gates.sh here and e040's build_all.sh and run_gates.sh in the same
# $FS_WORK (run.sh runs e040 first). This is not an oracle: both sides are the
# same compiler's object, run on the same QEMU machine, with and without Zephyr.
#
# Writes $RES/platforms.tsv:
#   same_kernel_object  bm040's kern.o and e040's kern.cortex-m33-zephyr.o are
#                       byte-identical (the profiles differ only in platform);
#   rows_match_zephyr   every case line, BEGIN and END aside, is the same.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
E040_OUT=${FS_WORK:-${TMPDIR:-/tmp}/spinel-freestanding}/e040
zlog="$E040_OUT/results/qemu_m33.log"
zobj="$E040_OUT/gen/kern.cortex-m33-zephyr.o"
for f in "$zlog" "$zobj" "$RES/qemu_bm.log" "$OUT/gen/kern.o"; do
  [ -f "$f" ] || { echo "$LANE: no $f (run e040 and this lane's run_gates.sh first)" >&2; exit 2; }
done

extract() {  # $1 = log -> case<TAB>result
  grep '^E040	' "$1" | grep -v '	BEGIN	\|	END	\|	FATAL	' | cut -f2- | tr -d '\r'
}
extract "$zlog" > "$RES/rows.zephyr.tsv"
extract "$RES/qemu_bm.log" > "$RES/rows.baremetal.tsv"
{
printf 'check\tdetail\tverdict\n'
if cmp -s "$OUT/gen/kern.o" "$zobj"; then v=PASS; d=identical; else v=FAIL; d=differ; fi
printf 'same_kernel_object\t%s\t%s\n' "$d" "$v"
n=$(wc -l < "$RES/rows.baremetal.tsv" | tr -d ' ')
if [ "$n" -gt 0 ] && cmp -s "$RES/rows.zephyr.tsv" "$RES/rows.baremetal.tsv"; then
  v=PASS; d="$n rows"
else
  v=FAIL; d="$(diff "$RES/rows.zephyr.tsv" "$RES/rows.baremetal.tsv" | grep -c '^[<>]') differing lines"
fi
printf 'rows_match_zephyr\t%s\t%s\n' "$d" "$v"
} > "$RES/platforms.tsv"
cat "$RES/platforms.tsv"
! grep -q FAIL "$RES/platforms.tsv"
