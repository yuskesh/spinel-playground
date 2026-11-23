#!/bin/sh
#
# tests/doom-core/rt1186-pair-controls.sh -- decision 0027's board controls of
# the pair's channel: each planted by the build, written, and refused by name
# on the board.
#
#   KERNEL=... SPINEL_TYPEDUMP=... LLVM_PREFIX=... ZEPHYR_BASE=... ZEPHYR_SDK_INSTALL_DIR=... \
#     [RT1186_HOST=user@host ...] [CONTROLS="pair-id consumer cacheable-cm7 cacheable-cm33 bell-notify bell-unrung bell-unenabled"] \
#     sh tests/doom-core/rt1186-pair-controls.sh LANE_DIR DIR
#
# LANE_DIR is a finished tests/doom-core/rt1186.sh run's DIR with RT1186_PAIR=1
# and DEMO1: its thumb entries and DEMO1's session image are taken from it as
# they are, as rt1186-play.sh takes them. For each control, pair.rb is built
# with companion.rb and the control's --mutate-* option, and its NOR image
# written (tools/doom/nor-image.rb); with a board (RT1186_HOST) the image is
# written and its console read from the lane's own reset, as rt1186.sh does:
#
#   pair-id         (control 4) --mutate-pair-id: the companion publishes
#                   another pair id than the M7 checks, as two builds written
#                   together would; the M7 refuses at its pair step and the
#                   M33 prints SPC_CHANNEL_REFUSED cm7 3 90, and no frame is
#                   relayed
#   consumer        (control 5) --mutate-consumer-stopped console: the M33
#                   never checks its end, so nothing takes; read with the
#                   debugger after the M33's report and 5 s of the run, the
#                   channel's line P has accepted = 16 (its depth), refused
#                   above 0 and attempted = accepted + refused, and line C a
#                   STOPPED consumer that took nothing
#   cacheable-cm7   (control 6) --mutate-channel-cacheable cm7: the M7's MPU
#                   maps the region cacheable; the M7 refuses at its MPU step
#                   and the M33 prints SPC_CHANNEL_REFUSED cm7 1
#   cacheable-cm33  (control 6) --mutate-channel-cacheable cm33: the M33's MPU
#                   maps it cacheable; the M33 writes nothing of the region and
#                   prints SPC_CHANNEL_REFUSED mpu cm33
#   bell-notify     (decision 0028) --mutate-doorbell-notify cm7: the M7's
#                   check wants another notify than the companion wrote; the
#                   M7 refuses at its channel step, naming the flags word,
#                   and the M33 prints SPC_CHANNEL_REFUSED cm7 5 131; no
#                   frame relayed
#   bell-unrung     (0028) --mutate-doorbell-unrung console: the put never
#                   rings; read with the debugger after the M33's report and
#                   5 s of the run, the relay has taken lines at its period
#                   alone: taken above 0, rung 0 and woken 0
#   bell-unenabled  (0028) --mutate-doorbell-unenabled: the consumer never
#                   enables the MU's interrupt, and says so
#                   (SPC_DOORBELL console MU1 GIR0 unenabled 0); the first
#                   ring sets GIR0, which no handler clears, so rung stays
#                   1, woken 0, and lines are still taken at the period
#
# Without RT1186_HOST the builds and images are made and the board part is a
# named skip. Each control writes the board, so they run once, at the end of
# the work (owner, 2026-10-20: long checks at the end).
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LANE=${1:?usage: rt1186-pair-controls.sh LANE_DIR DIR}
DIR=${2:?usage: rt1186-pair-controls.sh LANE_DIR DIR}
RUBY=${RUBY:-ruby}
CONTROLS=${CONTROLS:-pair-id consumer cacheable-cm7 cacheable-cm33 bell-notify bell-unrung bell-unenabled}
RT1186_BOARD=frdm_imxrt1186_cm7
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG; elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang; else CC_BIN=""; fi
die() { echo "rt1186-pair-controls: $*" >&2; exit 2; }
[ -n "$CC_BIN" ] || die "set LLVM_PREFIX or CLANG"
LLVM_BIN=${CC_BIN%/*}
[ -d "$LANE/thumb/session-objects" ] && [ -f "$LANE/image-DEMO1/image.tsv" ] ||
  die "$LANE is not a finished rt1186.sh run with DEMO1 (no thumb/session-objects or image-DEMO1)"
. "$ROOT/tools/test/source-stamp.sh"
KERNEL=${KERNEL:-$ROOT/tools/mlir/native/build/bin/spinel-core-kernel}
READER=${READER:-${SPINEL_TYPEDUMP:-$ROOT/tools/contract/build/spinel-typedump}}
source_stamp kernel "$KERNEL"
source_stamp reader "$READER"
"$RUBY" "$ROOT/tools/doom/objects-kernel.rb" --kernel "$KERNEL" \
  "$LANE/thumb/session-objects" || die "$LANE's entries were not built by this kernel: rebuild the lane, or give its KERNEL"
mkdir -p "$DIR" || exit 2
pass=0; fail=0; skip=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
T0=$(date +%s)
summary() {
  echo "rt1186-pair-controls: $((pass + fail)) checked, $pass pass, $fail fail, $skip part(s) skipped; $(( $(date +%s) - T0 )) s"
  if [ "${REQUIRE_ALL:-}" = 1 ] && [ "$skip" -ne 0 ]; then exit 1; fi
  [ "$fail" -eq 0 ]
  exit $?
}
mutate_of() {
  case $1 in
    pair-id) echo "--mutate-pair-id 0badc0de0badc0de" ;;
    consumer) echo "--mutate-consumer-stopped console" ;;
    cacheable-cm7) echo "--mutate-channel-cacheable cm7" ;;
    cacheable-cm33) echo "--mutate-channel-cacheable cm33" ;;
    bell-notify) echo "--mutate-doorbell-notify cm7" ;;
    bell-unrung) echo "--mutate-doorbell-unrung console" ;;
    bell-unenabled) echo "--mutate-doorbell-unenabled" ;;
    *) die "unknown control '$1' (pair-id consumer cacheable-cm7 cacheable-cm33 bell-notify bell-unrung bell-unenabled)" ;;
  esac
}

echo "== 1. the controls' builds and NOR images =="
for c in $CONTROLS; do
  KERNEL="$KERNEL" SPINEL_TYPEDUMP="$READER" \
    "$RUBY" "$ROOT/tools/app/bin/spinel-core-app" build --app "$ROOT/examples/doom/core/board/pair.rb" --board "$RT1186_BOARD" \
    --companion "$ROOT/examples/doom/core/board/companion.rb" $(mutate_of "$c") \
    --out "$DIR/fw-$c" --session-image "$LANE/image-DEMO1" --session-objects "$LANE/thumb/session-objects" > "$DIR/fw-$c.out" 2>&1
  rc=$?
  # the plant, as each leaves its mark: the log's control line, or the companion's main.c without its check
  case $c in
    pair-id) planted=$(grep -c '\[4\] pair: control: the companion publishes 0badc0de0badc0de' "$DIR/fw-$c/build.log" 2> /dev/null) ;;
    consumer) planted=$([ -f "$DIR/fw-$c/companion/firmware/main.c" ] && ! grep -q 'spc_channel_console_check()' "$DIR/fw-$c/companion/firmware/main.c" && echo 1) ;;
    bell-notify) planted=$(grep -c '\[1\] control: the cm7 image checks another notify' "$DIR/fw-$c/build.log" 2> /dev/null) ;;
    bell-unrung) planted=$(grep -c '\[1\] control: the put of console never rings' "$DIR/fw-$c/build.log" 2> /dev/null) ;;
    bell-unenabled) planted=$([ -f "$DIR/fw-$c/companion/firmware/main.c" ] && ! grep -q 'mbox_set_enabled(' "$DIR/fw-$c/companion/firmware/main.c" && echo 1) ;;
    *) planted=$(grep -c '\[2\] control: the channel region mapped cacheable on' "$DIR/fw-$c/build.log" 2> /dev/null) ;;
  esac
  ok "$c: the pair builds with its plant" "$rc|${planted:-0}" "0|1"
  "$RUBY" "$ROOT/tools/doom/nor-image.rb" --firmware "$DIR/fw-$c/firmware" --image "$LANE/image-DEMO1" --out "$DIR/nor-$c.bin" \
    --llvm "${LLVM_BIN%/bin}" > "$DIR/nor-$c.out" 2>&1
  ok "  its NOR image" "$?" 0
done
[ "$fail" -eq 0 ] || summary

if [ -z "${RT1186_HOST:-}" ]; then
  echo "  SKIP the board part: it needs RT1186_HOST" >&2
  skip=1
  summary
fi
echo "== 2. on the board =="
RT1186_RES=$DIR/board; mkdir -p "$RT1186_RES"
# a control's console ends at its refusal; a minute is far beyond the M33's 2 s wait
RT1186_TIMEOUT=${RT1186_TIMEOUT:-60}
# shellcheck source=tests/doom-core/harness/rt1186-host.sh
. "$ROOT/tests/doom-core/harness/rt1186-host.sh"
# shellcheck source=tests/doom-core/harness/rt1186-gdb.sh
. "$ROOT/tests/doom-core/harness/rt1186-gdb.sh"
rt_lock > "$RT1186_RES/lock.txt" 2>&1 || { cat "$RT1186_RES/lock.txt"; die "the board is not ours"; }
why=$(rt_ready) || die "no board: $why"
rt_open || exit 1
# the region's header in the M33's view, read once: rt_gdb_read waits for
# the previous read's gdbserver to end before it starts its own; its logs
# are the control's own (gdb-<control>.log, gdbserver-<control>.log)
read_header() { # name
  RT1186_GDB_CORE= RT1186_GDB_TAG=$1 rt_gdb_read "$RT1186_RES/$1-h.bin" 0x30500000 704 > "$RT1186_RES/$1_read.txt" 2>&1
}
for c in $CONTROLS; do
  rt_flash "$c" "$DIR/nor-$c.bin"
  ok "$c: the NOR image is written" "$?|$(grep -ciE 'finished|success' "$RT1186_RES/flash_$c.log" | awk '{ print ($1 > 0) ? "ok" : "no" }')" "0|ok"
  # the console ends at the refusal the M33 prints, or, for the consumer, after its report
  # the doorbell's controls end at the M33's SPC_DOORBELL line, which follows its report
  case $c in consumer) rt_console "$c" 0 SPC_M33_SESSION_ID ;; bell-unrung|bell-unenabled) rt_console "$c" 0 SPC_DOORBELL ;; *) rt_console "$c" 0 SPC_CHANNEL_REFUSED ;; esac
  log=$RT1186_RES/serial_$c.log
  from=$(cat "$RT1186_RES/serial_$c.reset" 2> /dev/null || echo 0)
  lines() { tail -c +$((from + 1)) "$log" | LC_ALL=C tr -d '\r\000' | LC_ALL=C grep -a "$1"; }
  frames=$(tail -c +$((from + 1)) "$log" | LC_ALL=C grep -a -c 'F 0000')
  case $c in
    pair-id)
      ok "pair-id: the M7 refuses the pair and the M33 says so; no frame relayed" \
         "$(lines '^SPC_CHANNEL_REFUSED' | head -1)|$frames" "SPC_CHANNEL_REFUSED cm7 3 90|0" ;;
    cacheable-cm7)
      ok "cacheable-cm7: the M7's MPU check refuses the region and the M33 says so; no frame relayed" \
         "$(lines '^SPC_CHANNEL_REFUSED' | head -1 | cut -d' ' -f1-3)|$frames" "SPC_CHANNEL_REFUSED cm7 1|0" ;;
    bell-notify)
      ok "bell-notify: the M7's channel check refuses the flags word (D + 2, plus 1) and the M33 says so; no frame relayed" \
         "$(lines '^SPC_CHANNEL_REFUSED' | head -1)|$frames" "SPC_CHANNEL_REFUSED cm7 5 131|0" ;;
    bell-unrung|bell-unenabled)
      sleep 5
      read_header "$c"
      ok "$c: the region's header is read" "$?" 0
      # line P of descriptor 0 at word 136 (rung its word 5), line C at word 144 (taken 4, woken 5)
      set -- $(od -A n -t u4 -v -j 544 -N 64 "$RT1186_RES/$c-h.bin" 2> /dev/null | tr -s ' \n' '  ')
      echo "  $c: P head ${1:-x} accepted ${4:-x} rung ${6:-x}; C tail ${9:-x} taken ${13:-x} woken ${14:-x}"
      want_rung=$([ "$c" = bell-unrung ] && echo 0 || echo 1)
      ok "$c: lines are taken at the period alone: taken above 0, rung $want_rung, woken 0" \
         "$([ "${13:-0}" -gt 0 ] && echo taken)|${6:-x}|${14:-x}" "taken|$want_rung|0"
      [ "$c" = bell-unenabled ] && ok "bell-unenabled: the M33 says the interrupt is not enabled" \
         "$(lines '^SPC_DOORBELL' | head -1)" "SPC_DOORBELL console MU1 GIR0 unenabled 0" ;;
    cacheable-cm33)
      ok "cacheable-cm33: the M33's MPU check refuses the region before writing it; no frame relayed" \
         "$(lines '^SPC_CHANNEL_REFUSED' | head -1 | cut -d' ' -f1-3)|$frames" "SPC_CHANNEL_REFUSED mpu cm33|0" ;;
    consumer)
      sleep 5
      read_header consumer
      ok "consumer: the region's header is read" "$?" 0
      # line P of descriptor 0 at word 136, line C at word 144 (ring_abi.h, version 5: the header is 704 bytes)
      set -- $(od -A n -t u4 -v -j 544 -N 52 "$RT1186_RES/consumer-h.bin" 2> /dev/null | tr -s ' \n' '  ')
      # head state attempted accepted refused rung . . | tail state fault waiting taken
      echo "  consumer: P head ${1:-x} attempted ${3:-x} accepted ${4:-x} refused ${5:-x}; C tail ${9:-x} state ${10:-x} taken ${13:-x}"
      # this control alone (the producer still putting; the drained counts stay exact): a put stores attempted before refused, so one read can find attempted one above
      _open=$(( ${3:-0} - ${4:-0} - ${5:-0} ))
      ok "consumer: the ring fills and put refuses: accepted 16, refused above 0, attempted = accepted + refused (or one above, a put between its two stores); the consumer STOPPED, nothing taken" \
         "${4:-x}|$([ "${5:-0}" -gt 0 ] && echo refused)|$([ "$_open" = 0 ] || [ "$_open" = 1 ] && echo closes)|${10:-x}|${13:-x}" \
         "16|refused|closes|0|0" ;;
  esac
done
summary
