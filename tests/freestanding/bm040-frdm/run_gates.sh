#!/usr/bin/env bash
# bm040-frdm checks, after build_all.sh: what the images contain, then both
# images on the board, through LinkServer on the Linux host ../frdm-host.sh
# describes (FRDM_HOST and the rest).
#
# Checks, each a row:
#   image.tsv  bm040's three image checks and their controls, here first: both
#              images have no undefined symbol; every input the linker used is
#              the lane's own driver objects, kern.o or a member of
#              BAREMETAL_BUILTINS; every symbol an image defines that those
#              objects do not is one the builtins archive defines; and each
#              check refuses bm_control.elf. These need no board.
#   ran.tsv    every case ran to END with no FATAL line;
#   trap.tsv   the six cases ../bm040/expect_trap.tsv names trap with its
#              code and no other case traps; the panic image prints its trap,
#              never reaches the line after the trapping call, and its core is
#              in the trap hook's final self-branch when halted (where bm040
#              asks whether QEMU is still running, the board is asked for its
#              PC), which an address outside that loop must fail (a control);
#              and both images arrived on the host intact and were written.
# Records, not checks: size.tsv, frdm.txt, the flash logs, the serial_*.log
# consoles and pc_bm_panic.log.
#
# Without the host or the board the image checks still run and are counted,
# and the script then exits 3 (NOT RUN, with the reason), or 1 if an image
# check failed; REQUIRE_ALL=1 makes NOT RUN a failure.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/../lane-env.sh"
. "$HERE/../frdm-host.sh"
: "${BAREMETAL_BUILTINS:?set BAREMETAL_BUILTINS (build_all.sh says how)}"
NMT="$LLVM_PREFIX/bin/llvm-nm"
SIZE="$LLVM_PREFIX/bin/llvm-size"
OBJDUMP="$LLVM_PREFIX/bin/llvm-objdump"
EXPECT_TRAP=$HERE/../bm040/expect_trap.tsv
FRDM_LABEL=$LANE
FRDM_RES=$RES
mkdir -p "$RES"
for f in "$OUT/bm.elf" "$OUT/bm_panic.elf" "$OUT/bm_control.elf" "$OUT/bm.bin" "$OUT/bm_panic.bin"; do
  [ -f "$f" ] || { echo "$LANE: no $f (run build_all.sh first)" >&2; exit 2; }
done
rm -f "$RES/ran.tsv" "$RES/trap.tsv" "$RES/not_run.txt" "$RES/run.bm.txt" "$RES/run.bm_panic.txt"

# --- what the images contain (bm040's checks, unchanged) ------------------------
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

cat "$RES/image.tsv"
if grep -q FAIL "$RES/image.tsv"; then
  echo "$LANE: an image check failed" >&2
  exit 1
fi

# --- the board --------------------------------------------------------------------
frdm_require
frdm_open
echo "kern.o $(frdm_sha "$OUT/gen/kern.o")" >> "$RES/frdm.txt"
echo "== board: bm =="
frdm_flash bm "$OUT/bm.bin"
frdm_console bm 'E040	(END|FATAL)' 0
echo "== board: bm_panic =="
frdm_flash bm_panic "$OUT/bm_panic.bin"
frdm_console bm_panic 'E040	(TRAP|FATAL)' 2
pc=$(frdm_pc bm_panic)

extract() {  # stdin = console lines -> case<TAB>result
  grep '^E040	' | grep -v '	BEGIN	\|	END	\|	FATAL	' | cut -f2-
}
frdm_last_run "$RES/serial_bm.log" > "$RES/run.bm.txt"
frdm_last_run "$RES/serial_bm_panic.log" > "$RES/run.bm_panic.txt"

# --- every case ran ------------------------------------------------------------
log="$RES/run.bm.txt"
ncases=$(( $(wc -l < "$OUT/gen/expect.tsv") - 1 ))
rows=$(extract < "$log" | sed '/^$/d' | wc -l | tr -d ' ')
end=$(grep -c '^E040	END' "$log" || true); fatal=$(grep -c '^E040	FATAL' "$log" || true)
if [ "$rows" = "$ncases" ] && [ "$end" -ge 1 ] && [ "$fatal" = 0 ]; then v=PASS; else v=FAIL; fi
{
printf 'target\tcases\trows\tend\tfatal\tverdict\n'
printf 'frdm-mcxn947\t%s\t%s\t%s\t%s\t%s\n' "$ncases" "$rows" "$end" "$fatal" "$v"
} > "$RES/ran.tsv"

# --- the traps, and the board's part ------------------------------------------------
# The trap hook's final `for (;;)` is a branch to itself; the halted PC must be
# one, inside spinel_trap.
self_branch_in_trap() {  # $1 = PC
  local start next
  start=$("$NMT" "$OUT/bm_panic.elf" | awk '$3 == "spinel_trap" {print $1}')
  next=$("$NMT" -n "$OUT/bm_panic.elf" | awk -v s="$start" 'f && $1 != s {print $1; exit} $1 == s {f = 1}')
  [ -n "$1" ] && [ -n "$start" ] && [ -n "$next" ] || return 1
  [ $(( $1 )) -ge $(( 0x$start )) ] && [ $(( $1 )) -lt $(( 0x$next )) ] || return 1
  "$OBJDUMP" -d --no-show-raw-insn --start-address="$1" --stop-address=$(( $1 + 2 )) "$OUT/bm_panic.elf" \
    | grep -Eqi "^ *${1#0x}:[[:space:]]+b(\.n|\.w)?[[:space:]]+0x0*${1#0x}"
}
{
printf 'check\twant\tgot\tverdict\n'
extract < "$log" > "$RES/rows.tsv"
awk -F'\t' 'NR>1 {print $2}' "$OUT/gen/expect.tsv" | while IFS= read -r c; do
  got=$(awk -F'\t' -v c="$c" '$1==c {print $2}' "$RES/rows.tsv")
  code=$(awk -F'\t' -v c="$c" 'NR>1 && $1==c {print $2}' "$EXPECT_TRAP")
  if [ -n "$code" ]; then
    want="trap:$code"
    [ "$got" = "$want" ] && v=PASS || v=FAIL
  else
    want="a value"
    case "$got" in ''|trap:*) v=FAIL ;; *) v=PASS ;; esac
  fi
  printf '%s\t%s\t%s\t%s\n' "$c" "$want" "${got:-none}" "$v"
done
plog="$RES/run.bm_panic.txt"
got=$(grep '^E040	TRAP	' "$plog" | head -1 | cut -f3)
# mulnarrow(46341, 46341) overflows the 32-bit body: code 1 (decision 0019,
# revised 2026-10-21; the 64-bit body refused it at the return, code 3).
case "$got" in 'code=1 '*) v=PASS ;; *) v=FAIL ;; esac
printf 'panic_trap_reached\tcode=1\t%s\t%s\n' "${got:-none}" "$v"
if grep -q '^E040	UNREACHABLE' "$plog"; then v=FAIL; got=reached; else v=PASS; got="not reached"; fi
printf 'panic_stops_execution\tnot reached\t%s\t%s\n' "$got" "$v"
self_branch_in_trap "$pc" && v=PASS || v=FAIL
printf 'panic_core_stays_in_its_loop\tself-branch in spinel_trap\tpc %s\t%s\n' "${pc:-none}" "$v"
# Its control: the reset entry is not that loop, and the check must say so.
ctl=0x$("$NMT" "$OUT/bm_panic.elf" | awk '$3 == "Reset_Handler" {print $1}')
self_branch_in_trap "$ctl" && v="FAIL (the check passed an address it must refuse)" || v=PASS
printf 'control_pc_outside_the_loop_refused\trefused\tpc %s\t%s\n' "$ctl" "$v"
for img in bm bm_panic; do
  eval "rs=\$FRDM_SUM_$img rc=\$FRDM_RC_$img"
  [ "$rs" = "$(frdm_sha "$OUT/$img.bin")" ] && v=PASS || v=FAIL
  printf 'image_transferred_%s\tsha256 of %s.bin\t%s\t%s\n' "$img" "$img" "$rs" "$v"
  frdm_flashed "$img" && v=PASS || v=FAIL
  printf 'flashed_%s\trc 0, finished\trc %s\t%s\n' "$img" "$rc" "$v"
done
} > "$RES/trap.tsv"

echo "---"; cat "$RES/ran.tsv"; echo "---"; cat "$RES/trap.tsv"
! grep -q 'FAIL' "$RES/ran.tsv" "$RES/trap.tsv" "$RES/image.tsv"
