#!/usr/bin/env bash
# bm040 device runs, after build_all.sh. QEMU's mps2-an521 (QEMU_ARM, not the
# Zephyr SDK's), stopped at the console's terminator as the Zephyr lanes are.
#
# Checks, each a row:
#   ran.tsv    every case ran to END with no FATAL line;
#   trap.tsv   the six cases expect_trap.tsv names trap with its code and no
#              other case traps; the panic image prints its trap, never reaches
#              the line after the trapping call, and is still looping;
#   image.tsv  both images have no undefined symbol; every input the linker
#              used is the lane's own driver objects, kern.o or a member of
#              BAREMETAL_BUILTINS; and every symbol an image defines that those
#              objects do not is one the builtins archive defines. The same
#              three checks must each refuse bm_control.elf, which carries an
#              input, a symbol and an unresolved reference of its own.
# Records, not checks: size.tsv and the qemu_*.log consoles.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
need_baremetal
NMT="$LLVM_PREFIX/bin/llvm-nm"
SIZE="$LLVM_PREFIX/bin/llvm-size"
QEMU_TIMEOUT=${QEMU_TIMEOUT:-120}
mkdir -p "$RES"

run_qemu() {   # $1 = image, $2 = log, $3 = terminator regex, $4 = seconds to keep running after it
  local elf=$1 log=$2 term=$3 settle=$4
  echo "== qemu: $(basename "$elf") =="
  : > "$RES/$log"
  "$QEMU_ARM" -machine mps2-an521 -cpu cortex-m33 -m 16 -display none \
      -monitor none -serial file:"$RES/$log" -kernel "$elf" 2>"$RES/$log.stderr" &
  local qpid=$!
  local i=0
  while [ $i -lt "$QEMU_TIMEOUT" ]; do
    grep -qE "$term" "$RES/$log" 2>/dev/null && break
    kill -0 "$qpid" 2>/dev/null || break
    sleep 1; i=$(( i + 1 ))
  done
  sleep "$settle"
  if kill -0 "$qpid" 2>/dev/null; then echo running > "$RES/$log.state"; else echo exited > "$RES/$log.state"; fi
  kill "$qpid" 2>/dev/null || true
  wait "$qpid" 2>/dev/null || true
}
run_qemu "$OUT/bm.elf"       qemu_bm.log    'E040	(END|FATAL)'  0
run_qemu "$OUT/bm_panic.elf" qemu_panic.log 'E040	(TRAP|FATAL)' 2

extract() {  # $1 = log -> case<TAB>result
  grep '^E040	' "$1" | grep -v '	BEGIN	\|	END	\|	FATAL	' | cut -f2- | tr -d '\r'
}

# --- every case ran ------------------------------------------------------------
log="$RES/qemu_bm.log"
ncases=$(( $(wc -l < "$OUT/gen/expect.tsv") - 1 ))
rows=$(extract "$log" | sed '/^$/d' | wc -l | tr -d ' ')
end=$(grep -c '^E040	END' "$log" || true); fatal=$(grep -c '^E040	FATAL' "$log" || true)
if [ "$rows" = "$ncases" ] && [ "$end" -ge 1 ] && [ "$fatal" = 0 ]; then v=PASS; else v=FAIL; fi
{
printf 'target\tcases\trows\tend\tfatal\tverdict\n'
printf 'mps2-an521\t%s\t%s\t%s\t%s\t%s\n' "$ncases" "$rows" "$end" "$fatal" "$v"
} > "$RES/ran.tsv"

# --- the traps ------------------------------------------------------------------
{
printf 'check\twant\tgot\tverdict\n'
extract "$log" > "$RES/rows.tsv"
awk -F'\t' 'NR>1 {print $2}' "$OUT/gen/expect.tsv" | while IFS= read -r c; do
  got=$(awk -F'\t' -v c="$c" '$1==c {print $2}' "$RES/rows.tsv")
  code=$(awk -F'\t' -v c="$c" 'NR>1 && $1==c {print $2}' "$HERE/expect_trap.tsv")
  if [ -n "$code" ]; then
    want="trap:$code"
    [ "$got" = "$want" ] && v=PASS || v=FAIL
  else
    want="a value"
    case "$got" in ''|trap:*) v=FAIL ;; *) v=PASS ;; esac
  fi
  printf '%s\t%s\t%s\t%s\n' "$c" "$want" "${got:-none}" "$v"
done
plog="$RES/qemu_panic.log"
got=$(grep '^E040	TRAP	' "$plog" | head -1 | cut -f3 | tr -d '\r')
# mulnarrow(46341, 46341) overflows the 32-bit body: code 1 (decision 0019,
# revised 2026-10-21; the 64-bit body refused it at the return, code 3).
case "$got" in 'code=1 '*) v=PASS ;; *) v=FAIL ;; esac
printf 'panic_trap_reached\tcode=1\t%s\t%s\n' "${got:-none}" "$v"
if grep -q '^E040	UNREACHABLE' "$plog"; then v=FAIL; got=reached; else v=PASS; got="not reached"; fi
printf 'panic_stops_execution\tnot reached\t%s\t%s\n' "$got" "$v"
state=$(cat "$plog.state")
[ "$state" = running ] && v=PASS || v=FAIL
printf 'panic_core_stays_in_its_loop\trunning\t%s\t%s\n' "$state" "$v"
} > "$RES/trap.tsv"

# --- what the images contain ------------------------------------------------------
"$NMT" --defined-only --format=just-symbols "$BAREMETAL_BUILTINS" 2>/dev/null \
  | grep -v ':$' | sed '/^$/d' | sort -u > "$RES/builtins_defined.txt"
image_checks() {  # $1 = image, $2 = its driver object -> three check rows
  local img=$1 drv=$2 elf="$OUT/$1.elf" undef others members notbuiltin v
  undef=$("$NMT" --undefined-only --format=just-symbols "$elf" | sed '/^$/d' | wc -l | tr -d ' ')
  [ "$undef" = 0 ] && v=PASS || v=FAIL
  printf '%s_undefined_symbols\t%s\t%s\n' "$img" "$undef" "$v"

  # The linker map names each input: the four objects, or archive(member).
  grep -oE '[^ ]+\.(o|obj|a\([^)]*\))' "$OUT/$img.map" | sort -u > "$RES/$img.inputs.txt"
  others=$(grep -v -F -e "$OUT/start.o" -e "$OUT/setjmp.o" -e "$OUT/$drv" -e "$OUT/gen/kern.o" \
             -e "$BAREMETAL_BUILTINS(" "$RES/$img.inputs.txt" | tr '\n' ' ')
  members=$(grep -F "$BAREMETAL_BUILTINS(" "$RES/$img.inputs.txt" | sed 's/.*(\(.*\))/\1/' | sort -u | tr '\n' ' ')
  [ -z "$others" ] && v=PASS || v=FAIL
  printf '%s_inputs_are_driver_kernel_builtins\tbuiltins: %s%s\t%s\n' "$img" "$members" \
    "${others:+; other: $others}" "$v"

  # Defined symbols the lane's objects and the linker script do not define.
  "$NMT" --defined-only --format=just-symbols "$OUT/start.o" "$OUT/setjmp.o" "$OUT/$drv" \
      "$OUT/gen/kern.o" 2>/dev/null | grep -v ':$' | sed '/^$/d' | sort -u > "$RES/$img.own.txt"
  printf '%s\n' __stack_top __data_start __data_end __data_load __bss_start __bss_end \
    >> "$RES/$img.own.txt"
  "$NMT" --defined-only --format=just-symbols "$elf" | sed '/^$/d' | sort -u \
    | grep -v -x -F -f "$RES/$img.own.txt" > "$RES/$img.foreign.txt" || true
  notbuiltin=$(grep -v -x -F -f "$RES/builtins_defined.txt" "$RES/$img.foreign.txt" | tr '\n' ' ')
  [ -z "$notbuiltin" ] && v=PASS || v=FAIL
  printf '%s_foreign_symbols_are_builtins\t%s%s\t%s\n' "$img" "$(tr '\n' ' ' < "$RES/$img.foreign.txt")" \
    "${notbuiltin:+; not in the builtins: $notbuiltin}" "$v"
}
{
printf 'check\tdetail\tverdict\n'
image_checks bm main.o
image_checks bm_panic main_panic.o
# The control: bm_control.elf carries control.o, a symbol it alone defines and
# a reference left unresolved, so each of the three checks must fail on it.
image_checks bm_control main.o | while IFS=$'\t' read -r check detail verdict; do
  [ "$verdict" = FAIL ] && v=PASS || v="FAIL (the check passed an image it must refuse)"
  printf 'control_%s_refused\t%s\t%s\n' "${check#bm_control_}" "$detail" "$v"
done
} > "$RES/image.tsv"

# --- size (a record, not a check) -------------------------------------------------
{
printf 'target\tkind\tname\tbytes\n'
printf 'cortex-m33-baremetal\tobject\ttext\t%s\n' "$($SIZE "$OUT/gen/kern.o" | awk 'NR==2{print $1}')"
for img in bm bm_panic; do
  $SIZE "$OUT/$img.elf" | awk -v b="$img" 'NR==2{printf "%s\timage\ttext\t%s\n%s\timage\tdata\t%s\n%s\timage\tbss\t%s\n", b,$1,b,$2,b,$3}'
done
} > "$RES/size.tsv"

cat "$RES/ran.tsv"; echo "---"; cat "$RES/trap.tsv"; echo "---"; cat "$RES/image.tsv"
! grep -q 'FAIL' "$RES/ran.tsv" "$RES/trap.tsv" "$RES/image.tsv"
