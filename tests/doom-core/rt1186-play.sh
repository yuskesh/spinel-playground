#!/bin/sh
#
# tests/doom-core/rt1186-play.sh -- decision 0025's board lane: DOOM played over the network.
#
#   KERNEL=... SPINEL_TYPEDUMP=... LLVM_PREFIX=... ZEPHYR_BASE=... ZEPHYR_SDK_INSTALL_DIR=... \
#     [PLAY_ADDR=A.B.C.D RT1186_HOST=user@host ...] [FRAMES_PORT=5029] [KEYS_PORT=5030] \
#     [TICS=1000] [SEND_SECONDS=10] [BAD=3] [GAP=1500] sh tests/doom-core/rt1186-play.sh LANE_DIR DIR
#
# LANE_DIR is a finished tests/doom-core/rt1186.sh run's DIR (RT1186_CORE=cm7):
# its thumb entries and DEMO1's session image are taken from it as they are,
# as rt1186-profile.sh takes them. Then:
#
#   1. tests/app/play.sh over them: play.rb on the host against decision
#      0025's rules, its controls, its stops, the console reader, the key
#      sender on the loopback, and the build with the keys switched off;
#   2. the network file, written by this lane into DIR, outside the
#      repository: the frames to PLAY_ADDR, this host, and the keys accepted
#      from PLAY_ADDR only (0025 point 7). PLAY_ADDR is this host's own LAN
#      address, given in the environment and never written into a tracked
#      file. Without it, the file switches both channels off (port 0) and the
#      board part is a named skip;
#   3. play.rb built for frdm_imxrt1186_cm7 with that file, and its NOR image
#      (tools/doom/nor-image.rb);
#   4. with a board (RT1186_HOST) and PLAY_ADDR: the image written and its
#      console read from the lane's own reset, as rt1186.sh does; meanwhile,
#      on THIS host, tools/doom/key-sender.rb receives the frames and sends
#      the keys -- SEND_SECONDS of them at 35 a second, BAD with a reserved bit, one
#      silence of GAP ms (above the 500 ms time-out), then all released. The
#      console must name the build, and its first TICS frames be tics in
#      order with every I line balanced, the last one counting from BAD to
#      BAD plus the sender's late messages bad (those it sent to the boot
#      before the judged one after that boot's last frame, which the judged
#      boot counts as bad), and two time-outs (the gap's, and the one after the sender
#      stops), and the boot judged must be the one the sender ended on;
#      and the M33's counts (spc_net, read with the debugger) must
#      balance, received = refused + empty + too long + full + queued, with
#      none refused, empty, too long or failed.
#
# The sender's spans from a send to the first frame naming it are reported
# as measurements. NOT A REALTIME CLAIM.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LANE=${1:?usage: rt1186-play.sh LANE_DIR DIR}
DIR=${2:?usage: rt1186-play.sh LANE_DIR DIR}
RUBY=${RUBY:-ruby}
TICS=${TICS:-1000}
SECONDS_SENT=${SEND_SECONDS:-10}
BAD=${BAD:-3}
GAP=${GAP:-1500}
FRAMES_PORT=${FRAMES_PORT:-5029}
KEYS_PORT=${KEYS_PORT:-5030}
for v in TICS SECONDS_SENT BAD GAP FRAMES_PORT KEYS_PORT; do
  eval "x=\$$v"
  case $x in ''|*[!0-9]*) echo "rt1186-play: $v must be a number, not '$x'" >&2; exit 2 ;; esac
done
RT1186_BOARD=frdm_imxrt1186_cm7
if [ -n "${CLANG:-}" ]; then CC_BIN=$CLANG; elif [ -n "${LLVM_PREFIX:-}" ]; then CC_BIN=$LLVM_PREFIX/bin/clang; else CC_BIN=""; fi
die() { echo "rt1186-play: $*" >&2; exit 2; }
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
  echo "rt1186-play: $((pass + fail)) checked, $pass pass, $fail fail, $skip part(s) skipped; $(( $(date +%s) - T0 )) s; not a realtime claim"
  if [ "${REQUIRE_ALL:-}" = 1 ] && [ "$skip" -ne 0 ]; then exit 1; fi
  [ "$fail" -eq 0 ]
  exit $?
}

echo "== 1. tests/app/play.sh =="
SESSION_IMAGE="$LANE/image-DEMO1" SESSION_OBJECTS="$LANE/thumb/session-objects" KERNEL="$KERNEL" SPINEL_TYPEDUMP="$READER" \
  CLANG="$CC_BIN" sh "$ROOT/tests/app/play.sh" "$DIR/play" > "$DIR/play.out" 2>&1
ok "tests/app/play.sh" \
   "$?|$(awk '/^play: [0-9]+ checked, / && $2 == $4 && $6 == "0" && $8 == "0" { n++ } END { print n + 0 }' "$DIR/play.out")" "0|1"
sed 's/^/    /' "$DIR/play.out"

echo "== 2. the network file =="
NET=$DIR/play.net
if [ -n "${PLAY_ADDR:-}" ]; then
  printf 'interface swp0\naddress dhcp\nnetmask dhcp\nchannel frames %s %s\ninbound keys %s from %s\n' \
    "$PLAY_ADDR" "$FRAMES_PORT" "$KEYS_PORT" "$PLAY_ADDR" > "$NET"
  echo "  the frames to this host at $FRAMES_PORT, the keys on the board's $KEYS_PORT from this host only (PLAY_ADDR)"
else
  cp "$ROOT/tests/app/fixtures/play/port0.net" "$NET"
  echo "  PLAY_ADDR is not set: both channels off (port 0)"
fi

echo "== 3. play.rb for $RT1186_BOARD =="
rm -rf "$DIR/fw"
KERNEL="$KERNEL" SPINEL_TYPEDUMP="$READER" \
  "$RUBY" "$ROOT/tools/app/bin/spinel-core-app" build --app "$ROOT/examples/doom/core/board/play.rb" --board "$RT1186_BOARD" \
  --out "$DIR/fw" --session-image "$LANE/image-DEMO1" --session-objects "$LANE/thumb/session-objects" --net "$NET" > "$DIR/fw.out" 2>&1
ok "play.rb builds with the lane's network file" "$?|$([ -f "$DIR/fw/firmware/zephyr.elf" ] && echo elf)" "0|elf"
"$RUBY" "$ROOT/tools/doom/nor-image.rb" --firmware "$DIR/fw/firmware" --image "$LANE/image-DEMO1" --out "$DIR/nor-play.bin" \
  --llvm "${LLVM_BIN%/bin}" > "$DIR/nor.out" 2>&1
ok "  its NOR image, within the 16 MB NOR, the FlexSPI configuration block at 0x400" \
   "$?|$([ "$(wc -c < "$DIR/nor-play.bin" 2>/dev/null || echo 99999999)" -le 16777216 ] && echo fits)|$(od -A n -c -j 1024 -N 4 "$DIR/nor-play.bin" 2>/dev/null | tr -d ' ')" "0|fits|FCFB"
ID=$("$RUBY" -rjson -e 'puts JSON.parse(File.read(ARGV[0])).dig("session", "id").to_s' "$DIR/fw/firmware/build.json" 2>/dev/null)

echo "== 4. on the board =="
if [ "$fail" -ne 0 ]; then
  echo "  nothing is written after a failure"
  summary
fi
if [ -z "${PLAY_ADDR:-}" ] || [ -z "${RT1186_HOST:-}" ]; then
  echo "  SKIP the board part: it needs PLAY_ADDR (this host's LAN address) and RT1186_HOST" >&2
  skip=1
  summary
fi
RT1186_RES=$DIR/board; mkdir -p "$RT1186_RES"
# shellcheck source=tests/doom-core/harness/rt1186-host.sh
. "$ROOT/tests/doom-core/harness/rt1186-host.sh"
# shellcheck source=tests/doom-core/harness/rt1186-gdb.sh
. "$ROOT/tests/doom-core/harness/rt1186-gdb.sh"
rt_lock > "$RT1186_RES/lock.txt" 2>&1 || { cat "$RT1186_RES/lock.txt"; die "the board is not ours"; }
why=$(rt_ready) || die "no board: $why"
rt_open || exit 1
rt_flash play "$DIR/nor-play.bin" || die "the write failed; see $RT1186_RES/flash_play.log"
grep -qiE 'finished|success' "$RT1186_RES/flash_play.log" || die "the write did not say it finished; see $RT1186_RES/flash_play.log"
# the sender on this host, from before the console is read: it waits for the
# first frame, which comes once the M33 has its address, and follows the
# newest boot, so the console's own reset starts its script again
"$RUBY" "$ROOT/tools/doom/key-sender.rb" --frames-port "$FRAMES_PORT" --keys-port "$KEYS_PORT" --seconds "$SECONDS_SENT" \
  --bad "$BAD" --gap "$GAP" --wait 180 --out "$DIR/sender" > "$DIR/sender.out" 2>&1 &
ks=$!
rt_console play "$TICS"
wait "$ks"
ok "the key sender saw the board's frames and sent its keys" "$?" 0
sed 's/^/  /' "$DIR/sender.out"
HZ=$(sed -n 's/^CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=//p' "$DIR/fw/firmware/config")
TIMEOUTS=$(( GAP > 0 ? 2 : 1 ))
# the bad count: the BAD planted, and at most the sender's late messages to
# the boot before the judged one, which that boot counts as bad (the coordinator,
# 2026-10-23)
LATE=$(sed -n 's/.*(the last of [0-9]*), session [0-9a-f]*; sent [0-9]* to it (bad [0-9]*, gaps [0-9]*, late \([0-9]*\)).*/\1/p' "$DIR/sender.out")
"$RUBY" "$ROOT/tools/doom/board-frames.rb" --play --console "$RT1186_RES/serial_play.log" --from "$(cat "$RT1186_RES/serial_play.reset")" \
  --identity "$ID" --tics "$TICS" --hz "$HZ" --expect-bad "$BAD" --expect-bad-max "$(( BAD + ${LATE:-0} ))" --expect-timeouts "$TIMEOUTS" > "$DIR/frames.out" 2>&1
ok "board-frames --play admits the console: the build, $TICS tics in order, every I line balanced, $BAD to $(( BAD + ${LATE:-0} )) bad, $TIMEOUTS time-outs" "$?" 0
sed 's/^/  /' "$DIR/frames.out"
# THE BOOT JUDGED IS THE BOOT THE SENDER ENDED ON. The write's reset starts a
# boot before the lane's own reset starts the one that is read; a sender that
# kept the first boot's id sent every key of the judged run to a boot that
# no longer existed (2026-10-23). The judged boot is the B line of the run
# board-frames reads (from the first banner after the lane's reset), read here
# whether or not board-frames admitted it; the sender names its last.
judged=$("$RUBY" -I"$ROOT/tools/app/lib" -rcore_app/console -e '
  raw = File.binread(ARGV[0]); s = raw.index("*** Booting Zephyr".b, Integer(File.read(ARGV[1]).strip, 10)) or exit
  b = CoreApp::Console.parse(raw.byteslice(s..)).frames.map { |_, x| x.pack("C*") }.grep(/\AB 00000000(\h{8})\n\z/).first
  puts b[10, 8] if b' "$RT1186_RES/serial_play.log" "$RT1186_RES/serial_play.reset" 2>/dev/null)
last=$(sed -n 's/.*, boot \([0-9a-f]\{8\}\) (the last of [0-9]*).*/\1/p' "$DIR/sender.out" | head -n 1)
ok "the boot judged (its B line) is the boot the sender sent its script to last" "${judged:-none}" "${last:-unknown}"
# the M33's side (decision 0025 point 2): spc_net's 21 words
addr=$("$LLVM_BIN/llvm-nm" "$DIR/fw/firmware/launcher.elf" 2> /dev/null | awk '$3 == "spc_net" { print $1 }')
RT1186_GDB_CORE= rt_gdb_read "$RT1186_RES/net.bin" "0x$addr" 84 > "$RT1186_RES/net_read.txt" 2>&1
ok "the M33's counts are read (spc_net, magic SPNC)" "$?|$(od -A n -t u4 -v -N 4 "$RT1186_RES/net.bin" 2>/dev/null | tr -d ' ')" "0|1129205843"
set -- $(od -A n -t u4 -v "$RT1186_RES/net.bin" 2>/dev/null | tr -s ' \n' '  ')
# magic errors taken sent discarded retries pending in_send fault boot state dhcp_ms tail
#   received refused empty too_long full queued in_errors in_head
echo "  net: received ${14:-?} refused ${15:-?} empty ${16:-?} too long ${17:-?} full ${18:-?} queued ${19:-?} receive errors ${20:-?}; sent ${4:-?} errors ${2:-?} retries ${6:-?}"
ok "the M33's receive balances: received = refused + empty + too long + full + queued" \
   "${14:-x}" "$(( ${15:-0} + ${16:-0} + ${17:-0} + ${18:-0} + ${19:-0} ))"
ok "  none refused, empty, too long or failed, and no send error or fault" "${15:-x}|${16:-x}|${17:-x}|${20:-x}|${2:-x}|${9:-x}" "0|0|0|0|0|0"
sent=$(sed -n 's/.*(the last of [0-9]*), session [0-9a-f]*; sent \([0-9]*\) to it.*/\1/p' "$DIR/sender.out")
echo "  the sender sent ${sent:-?} to the last boot, its M33 received ${14:-?}: the difference is the network's loss, not the ring's"
summary
