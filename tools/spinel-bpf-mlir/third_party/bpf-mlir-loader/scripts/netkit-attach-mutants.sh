#!/bin/bash
# E067: docs/experiments/results/E067/mutants.tsv の変異ごとに、落ちた ID の集合が予測と完全に一致するか (rc と集合の両方)。kernel・root に触れない。
# 使い方: scripts/netkit-attach-mutants.sh UNIT_OUT (target-rows-unit.sh が作った dir の ELF を使う)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
UNIT="$(cd "${1:?netkit-attach-mutants.sh UNIT_OUT}" && pwd)"
TSV="$HERE/docs/experiments/results/E067/mutants.tsv"
T="$HERE/build/tools-mut"
W="$UNIT/netkit-mutants"; mkdir "$W"
die() { echo "netkit-attach-mutants: $*" >&2; exit 1; }

names=$(cut -f1 "$TSV" | grep -v '^#' | LC_ALL=C sort -u)
for f in abi/netkit.c abi/netkit_finish.c; do
  for m in $(grep -o 'BML_MUT("[a-z_.]*")' "$HERE/src/$f" | sed 's/BML_MUT("//;s/")//' | LC_ALL=C sort -u); do
    printf '%s\n' "$names" | grep -qxF "$m" || die "表に無い変異: $m ($f)"
  done
done
for m in $names; do grep -rqF "BML_MUT(\"$m\")" "$HERE/src" || die "source に無い変異: $m"; done

"$T/netkit_finish_unit" > "$W/base.log" 2>&1 || { cat "$W/base.log"; die '変異なしの unit が落ちた'; }
count=0 bad=0
while IFS=$'\t' read -r m runner ids; do
  case "$m" in ''|\#*) continue ;; esac
  log="$W/$m.log"; rc=0; got=''
  case "$runner" in
    finish)
      BML_MUTANT="$m" "$T/netkit_finish_unit" > "$log" 2>&1 || rc=$?
      got=$(grep ': FAIL$' "$log" | sed 's/: FAIL$//' || true) ;;
    guard) # open の後に印の立たない fentry.s/ の ELF だけを数える。変異なしでは同じ ELF に印が立つ
      BML_MUTANT="$m" "$T/target_rows_case" guard "$UNIT/stop/copy.bpf.o" > "$log" 2> "$log.err" || rc=$?
      [ "$rc" = 0 ] || { echo "MISMATCH $m: 子の異常終了 ($rc)"; bad=$((bad + 1)); continue; }
      got=$(grep -P '\trc=0\tsleepable=0$' "$log" | cut -f1 || true)
      "$T/target_rows_case" guard "$UNIT/stop/copy.bpf.o" > "$log.ctl" 2>> "$log.err" || die "対照の target_rows_case が異常終了"
      grep -qP '^copy\.bpf\.o\trc=0\tsleepable=1$' "$log.ctl" || die "変異なしの対照に印が立たない: $(cat "$log.ctl")"
      [ -z "$got" ] || rc=1 ;;
    sections)
      BML_MUTANT="$m" "$T/target_rows_case" shape "$UNIT"/stop/*.bpf.o > "$log" 2>&1 || rc=$?
      [ "$rc" = 0 ] || { echo "MISMATCH $m: 子の異常終了 ($rc)"; bad=$((bad + 1)); continue; }
      got=$(grep -P '\trc=-?[1-9][0-9]*\tstage=[^\t]*\t.*(netkit/(primary|peer)|fentry\.s/)' "$log" | cut -f1 | xargs -r -n1 basename || true)
      [ -z "$got" ] || rc=1 ;;
    *) die "知らない runner: $runner" ;;
  esac
  [ "$rc" = 1 ] || { head -5 "$log" >&2; echo "MISMATCH $m: rc が 1 でない ($rc)"; bad=$((bad + 1)); continue; }
  want=$(printf '%s\n' $ids | LC_ALL=C sort)
  have=$(printf '%s\n' "$got" | LC_ALL=C sort)
  [ "$want" = "$have" ] || { echo "MISMATCH $m: want [$(echo $want)] got [$(echo $have)]"; bad=$((bad + 1)); continue; }
  count=$((count + 1))
done < "$TSV"
[ "$bad" = 0 ] || die "$bad 変異が予測と違う"
[ "$count" -gt 0 ] || die "変異が 0 件"
echo "netkit-attach-mutants: $count 変異、全て予測の ID の集合と一致、kernel0"
