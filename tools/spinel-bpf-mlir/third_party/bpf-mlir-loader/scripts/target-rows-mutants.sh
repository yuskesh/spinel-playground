#!/bin/bash
# E066 H6: docs/experiments/results/E066/mutants.tsv の変異ごとに、落ちた ID の集合が予測と完全に一致するか。rc と集合の両方を見る。kernel・root に触れない。
# 使い方: scripts/target-rows-mutants.sh UNIT_OUT (target-rows-unit.sh が作った dir — Go の出力と ELF の変形をそのまま使う)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
UNIT="$(cd "${1:?target-rows-mutants.sh UNIT_OUT}" && pwd)"
TSV="$HERE/docs/experiments/results/E066/mutants.tsv"
T="$HERE/build/tools-mut"
F="$HERE/test/req/fixture/target_rows"
W="$UNIT/mutants"; mkdir "$W"
die() { echo "target-rows-mutants: $*" >&2; exit 1; }

# 目録: 新しい file の変異は全て表に在り、表の変異は全て source に在る
names=$(cut -f1 "$TSV" | grep -v '^#' | LC_ALL=C sort -u)
for f in req/parse_target_rows.c req/check_target_rows.c req/from_elf_sleepable.c caps/recorded_target_rows.c caps/live_target_rows.c; do
  for m in $(grep -o 'BML_MUT("[a-z_.]*")' "$HERE/src/$f" | sed 's/BML_MUT("//;s/")//' | LC_ALL=C sort -u); do
    printf '%s\n' "$names" | grep -qxF "$m" || die "表に無い変異: $m ($f)"
  done
done
for m in $names; do grep -rqF "BML_MUT(\"$m\")" "$HERE/src" || die "source に無い変異: $m"; done

# paste した 2 つの出力の違う行の先頭の欄 (path は basename)
differing() { diff "$1" "$2" | awk -F'\t' '/^< /{ sub(/^< /,""); n=split($1,p,"/"); print p[n] }'; }
strip_txt() { sed 's/\.txt$//'; }

count=0 bad=0
while IFS=$'\t' read -r m runner ids; do
  case "$m" in ''|\#*) continue ;; esac
  log="$W/$m.log"; rc=0; got=''; fixture=0
  case "$runner" in
    corpus-parse|corpus-cases)
      BML_MUTANT="$m" "$HERE/scripts/$runner.sh" "$T" > "$log" 2>&1 || rc=$?
      got=$(grep '^DIFF' "$log" | awk '{print $2}' | tr -d : || true) ;;
    fixture-parse)
      fixture=1
      BML_MUTANT="$m" "$T/parse_case" -m "$F"/parse/*.txt > "$log" 2> "$log.err" || rc=$?
      got=$(differing "$UNIT/parse.go" "$log" | strip_txt || true) ;;
    fixture-caps)
      fixture=1
      BML_MUTANT="$m" "$T/target_rows_case" caps "$F"/caps/*.json > "$log" 2> "$log.err" || rc=$?
      got=$(differing "$UNIT/caps.go" "$log" || true) ;;
    fixture-elf)
      fixture=1
      BML_MUTANT="$m" "$T/target_rows_case" elf "$UNIT"/elf/*.bpf.o > "$log" 2> "$log.err" || rc=$?
      got=$(differing "$UNIT/elf.go" "$log" || true) ;;
    fixture-cases)
      BML_MUTANT="$m" "$UNIT/recorded-check" "$F/cases" "$T/check_case" "$W/$m-recorded" > "$log" 2>&1 || rc=$?
      got=$(grep '^DIFF ' "$log" | awk '{print $2}' || true) ;;
    live)
      BML_MUTANT="$m" "$T/live_target_rows_unit" > "$log" 2>&1 || rc=$?
      got=$(grep ': FAIL$' "$log" | sed 's/: FAIL$//' || true) ;;
    live-close)
      BML_MUTANT="$m" "$UNIT/live_close.mut" > "$log" 2>&1 || rc=$?
      got=$(grep ': FAIL$' "$log" | sed 's/: FAIL$//' || true) ;;
    *) die "知らない runner: $runner" ;;
  esac
  if [ "$fixture" = 1 ]; then # 子は比較するだけの道具: 0 以外の終了 (2・139 等) は異常で、差の ID が一致しても検出に数えない
    [ "$rc" = 0 ] || { head -5 "$log.err" >&2; echo "MISMATCH $m: 子の異常終了 ($rc)"; bad=$((bad + 1)); continue; }
    [ -z "$got" ] || rc=1
  fi
  [ "$rc" = 1 ] || { head -5 "$log" >&2; echo "MISMATCH $m: rc が 1 でない ($rc)"; bad=$((bad + 1)); continue; }
  want=$(printf '%s\n' $ids | LC_ALL=C sort)
  have=$(printf '%s\n' "$got" | LC_ALL=C sort)
  [ "$want" = "$have" ] || { echo "MISMATCH $m: want [$(echo $want)] got [$(echo $have)]"; bad=$((bad + 1)); continue; }
  count=$((count + 1))
done < "$TSV"
[ "$bad" = 0 ] || die "$bad 変異が予測と違う"
[ "$count" -gt 0 ] || die "変異が 0 件"
echo "target-rows-mutants: $count 変異、全て予測の ID の集合と一致、kernel0"
