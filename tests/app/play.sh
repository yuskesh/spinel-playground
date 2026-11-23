#!/bin/sh
#
# tests/app/play.sh -- decision 0025: examples/doom/core/board/play.rb, DOOM
# played from a host keyboard.
#
#   SESSION_IMAGE=DIR [SESSION_OBJECTS=DIR ZEPHYR_BASE=... ZEPHYR_SDK_INSTALL_DIR=...
#     KERNEL=... SPINEL_TYPEDUMP=... CLANG=...|LLVM_PREFIX=...] sh tests/app/play.sh [WORKDIR]
#
# SESSION_IMAGE is DEMO1's session image and SESSION_OBJECTS the three
# entries built for thumbv8m, as tests/app/session.sh takes them; the board
# lane makes both.
#
# WHAT IT CHECKS
#   1. On the host (CoreApp::SessionHost, the clock moving one tic period a
#      release; tests/app/fixtures/play/host.rb), against values written by
#      hand from decision 0025's rules, not from a run:
#      - no message: every count 0, every frame "no input" (0:0:0), every
#        command 0;
#      - each bad kind (length, kind, version, session 0, a reserved bit, a
#        wrong boot id) counted and not used;
#      - within a tic, after 10: 12 then 11 applies 12 (11 stale); 13 then 13
#        applies one (the other stale); 14 then 15 applies 15 (14
#        superseded); the frames name the sequence used;
#      - the counts wrap: 0xffffffff then 0 is newer, 2^31 on is stale;
#      - the time-out at tic 19 (500 ms after the message applied at tic 1)
#        releases the keys, once, the frame saying 2; a delayed copy of 5 is
#        stale and does not resume; 6 resumes; another session meanwhile is
#        bad;
#      - after the time-out another session takes over with any number; the
#        old one is then bad;
#      - two sessions in one tic of an unbound board: the first binds;
#      - 20 messages at once: the channel holds 16 (4 full), the tic takes
#        16, 15 superseded and 1 applied;
#      - the commands of tests/app/fixtures/play/commands.tsv, mask by mask;
#      - dequeued = bad + stale + superseded + applied in every case.
#   2. CONTROLS, each a copy of play.rb with one rule broken, which must
#      fail the check above it: a newer message that does not move the
#      high-water; a time-out that does not release the keys; no exit check.
#   3. The stops (point 14), from images with one core_state slot planted
#      (fixtures/play/plant.rb): the exit stops before the input and the
#      step; use while dead (PST_REBORN) stops before the step; death alone
#      does not stop; an input entry that fails (planted status 4) stops
#      before the step and the render, so the failed call's storage is not
#      used again.
#   3b. tools/doom/board-frames.rb --play over planted consoles
#      (fixtures/play/consoles.rb): the clean one and the expected bad count
#      admitted, and a bad count within the range of planted and late at
#      either end; a different bad count, one below or above that range, an
#      unbalanced I line, a count that
#      goes down, no I line, a D line, a stop before the tics, frames out of
#      order and more tics applied than ran, each refused by name.
#   3c. tools/doom/key-sender.rb on the loopback against
#      fixtures/play/fake-board.rb: it learns the board's address and boot id
#      from the first frame, and the board receives every message, the
#      planted bad ones and the gap as it was told to send them; and when
#      the fake board is reset into a new boot, the sender follows it,
#      starting the script again from the top for it with its sequence
#      numbers going on, and says per boot what it sent; and when the
#      frames stop for 0.6 s, the sender stops sending and goes on where it
#      stopped once they return.
#   4. With SESSION_OBJECTS and the build's tools: play.rb builds for
#      frdm_imxrt1186_cm7 with fixtures/play/port0.net, its M7 image has the
#      keys channel's get and the frames channel's put, and the get checks
#      ring ABI version 5 (decisions 0027 and 0028: a 512-byte header) with the keys
#      ring after the frames ring.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
export ROOT
W=${1:-${TMPDIR:-/tmp}/app-play.$$}
RUBY=${RUBY:-ruby}
TOOL=$ROOT/tools/app/bin/spinel-core-app
F=$ROOT/tests/app/fixtures/play
APP=$ROOT/examples/doom/core/board/play.rb
pass=0; fail=0; skip=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
T0=$(date +%s)
summary() {
  echo "play: $((pass + fail)) checked, $pass pass, $fail fail, $skip lane(s) skipped; $(( $(date +%s) - T0 )) s"
  if [ "${REQUIRE_ALL:-}" = 1 ] && [ "$skip" -ne 0 ]; then exit 1; fi
  [ "$fail" -eq 0 ]
  exit $?
}
if [ -z "${SESSION_IMAGE:-}" ] || [ ! -f "${SESSION_IMAGE:-}/image.tsv" ]; then
  echo "  SKIP the play lane: SESSION_IMAGE is not set or holds no image.tsv" >&2
  skip=1
  summary
fi
mkdir -p "$W" || exit 2
host() { # image app scenario -> its line
  "$RUBY" -I"$ROOT/tools/app/lib" "$F/host.rb" "$1" "$2" "$3" 2>> "$W/host.err" | tail -n 1
}
field() { # line name -> the value after name=
  printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"
}
metas() { # line -> the meta list
  printf '%s\n' "$1" | sed -n 's/.* meta=\(.*\) cmds=.*/\1/p'
}
cmds() { # line -> the command list
  printf '%s\n' "$1" | sed -n 's/.* cmds=\(.*\) full=.*/\1/p'
}
balanced() { # counts -> yes when dequeued = bad + stale + superseded + applied
  echo "$1" | awk -F, '{ print ($1 == $2 + $3 + $4 + $5) ? "yes" : "no" }'
}
rep() { # value n -> value repeated n times, space-separated
  i=0; out=""; while [ "$i" -lt "$2" ]; do out="$out${out:+ }$1"; i=$((i + 1)); done; echo "$out"
}
Z=0,0,0,0,0

echo "play: 1. the keys on the host, over DEMO1's session"
r=$(host "$SESSION_IMAGE" "$APP" none)
ok "no message: every count 0, every frame no input, every command 0" \
   "$(field "$r" counts)|$(metas "$r")|$(cmds "$r")" "0,0,0,0,0,0,0|$(rep 0:0:0 6)|$(rep $Z 6)"
r=$(host "$SESSION_IMAGE" "$APP" bad)
ok "six bad messages (length, kind, version, session 0, a reserved bit, another boot) are counted and not used" \
   "$(field "$r" counts)|$(metas "$r")" "6,6,0,0,0,0,0|$(rep 0:0:0 4)"
r=$(host "$SESSION_IMAGE" "$APP" intic)
INTIC=$r
ok "within a tic: 12,11 applies 12; 13,13 applies one; 14,15 applies 15; the frames name the sequence used" \
   "$(field "$r" counts)|$(metas "$r")" "7,0,2,1,4,4,0|0:0:0 A:10:1 A:12:1 A:13:1 A:15:1 A:15:1"
r=$(host "$SESSION_IMAGE" "$APP" wrap)
ok "the counts wrap: 0xffffffff then 0 is newer, and 2^31 on is stale" \
   "$(field "$r" counts)|$(metas "$r")" "3,0,1,0,2,2,0|0:0:0 A:4294967295:1 A:0:1 A:0:1 A:0:1"
r=$(host "$SESSION_IMAGE" "$APP" timeout)
TIMEOUT=$r
UP=25,0,0,0,0
ok "the time-out at tic 19 releases the keys once; a delayed 5 is stale; 6 resumes; another session meanwhile is bad" \
   "$(field "$r" counts)|$(metas "$r")|$(cmds "$r")" \
   "4,1,1,0,2,2,1|0:0:0 $(rep A:5:1 18) $(rep A:5:2 3) $(rep A:6:1 3)|$Z $(rep $UP 18) $(rep $Z 3) $(rep $UP 3)"
r=$(host "$SESSION_IMAGE" "$APP" takeover)
DOWN=-25,0,0,0,0
ok "after the time-out another session takes over with a lower number; the old one is then bad" \
   "$(field "$r" counts)|$(metas "$r")|$(cmds "$r")" \
   "4,1,0,0,3,3,1|0:0:0 $(rep A:5:1 18) A:5:2 B:3:1 B:3:1 B:4:1 B:4:1|$Z $(rep $UP 18) $Z $(rep $DOWN 4)"
r=$(host "$SESSION_IMAGE" "$APP" sametic)
ok "two sessions in the tic of an unbound board: the first binds, the second is bad" \
   "$(field "$r" counts)|$(metas "$r")" "2,1,0,0,1,1,0|0:0:0 A:5:1 A:5:1"
r=$(host "$SESSION_IMAGE" "$APP" full)
ok "20 at once: 16 queued (4 full), 15 superseded, 16 applied" \
   "$(field "$r" counts)|$(field "$r" full)|$(metas "$r")" "16,0,0,15,1,1,0|4|0:0:0 A:16:1 A:16:1"
r=$(host "$SESSION_IMAGE" "$APP" commands)
want=$(grep -v '^#' "$F/commands.tsv" | awk -F'\t' 'NF >= 6 { printf "%s%s,%s,%s,%s,%s", (n++ ? " " : ""), $2, $3, $4, $5, $6 }')
ok "the commands of fixtures/play/commands.tsv, mask by mask, from tic 1" "$(cmds "$r")" "$Z $want $Z"
b=""
for c in "$INTIC" "$TIMEOUT" "$r"; do b="$b$(balanced "$(field "$c" counts)")"; done
ok "dequeued = bad + stale + superseded + applied" "$b" yesyesyes

echo "play: 2. controls, each a copy of play.rb with one rule broken"
mutant() { # name ruby-edit -> the copy's path
  mkdir -p "$W/m-$1/board"
  ln -sfn "$ROOT/examples/doom/core/entries" "$W/m-$1/entries"
  "$RUBY" -e 's = File.read(ARGV[0]); a, b = ARGV[2], ARGV[3]; s.include?(a) or abort("the anchor moved: #{a}")
    File.write(ARGV[1], s.sub(a) { b })' "$APP" "$W/m-$1/board/play.rb" "$2" "$3" || exit 1
  echo "$W/m-$1/board/play.rb"
}
m=$(mutant hw "            inp[9] = inp[9] + 1 if cand == 1
            hw = seq
" "            inp[9] = inp[9] + 1 if cand == 1
")
r=$(host "$SESSION_IMAGE" "$m" intic)
ok "control: a newer message that does not move the high-water fails the in-tic check" \
   "$([ "$(metas "$r")" = "0:0:0 A:10:1 A:12:1 A:13:1 A:15:1 A:15:1" ] && echo passes || echo fails)" fails
m=$(mutant release "    inp[4] = 0
    inp[5] = 0
" "    inp[4] = 0
")
r=$(host "$SESSION_IMAGE" "$m" timeout)
ok "control: a time-out that does not release the keys fails the time-out check" \
   "$([ "$(cmds "$r")" = "$Z $(rep $UP 18) $(rep $Z 3) $(rep $UP 3)" ] && echo passes || echo fails)" fails

echo "play: 3. the stops, from planted images"
plant() { "$RUBY" "$F/plant.rb" "$SESSION_IMAGE" "$W/$1" "$2" "$3" || exit 1; }
plant exit game_exit_requested 1
plant reborn game_pl_playerstate 2
plant dead game_pl_playerstate 1
ok "the exit the last step requested stops before the input and the step" \
   "$(host "$W/exit" "$APP" stop)" "x=X 0000000000000000 exit 0000000000000001 frames=0 input=0 step=0 render=0"
m=$(mutant noexit "  return stop(line, pending, phase, t, \"exit\", 4, 1) if core_state[Slot::GAME_EXIT_REQUESTED] == 1
" "")
ok "control: without the exit check the planted exit runs on" \
   "$(host "$W/exit" "$m" stop | cut -d' ' -f1)" "x=none"
ok "use while dead (PST_REBORN) stops before the step" \
   "$(host "$W/reborn" "$APP" stop)" "x=X 0000000000000000 reborn 0000000000000000 frames=0 input=1 step=0 render=0"
ok "death alone does not stop the run" "$(host "$W/dead" "$APP" stop)" "x=none frames=3 input=4 step=4 render=4"
ok "a failing input entry stops before the step and the render" \
   "$(PLAY_PLANT=input host "$SESSION_IMAGE" "$APP" stop)" "x=X 0000000000000000 input 0000000000000004 frames=0 input=1 step=0 render=0"

echo "play: 3b. play.rb's console, read by board-frames.rb --play"
mkdir -p "$W/consoles"
"$RUBY" "$F/consoles.rb" "$W/consoles" > "$W/consoles/rows.tsv" || exit 1
while IFS="$(printf '\t')" read -r n tics bad want; do
  out=$("$RUBY" "$ROOT/tools/doom/board-frames.rb" --play --console "$W/consoles/$n.log" --identity 0123456789abcdef \
    --tics "$tics" $(case $bad in -) ;; *-*) echo --expect-bad "${bad%-*}" --expect-bad-max "${bad#*-}" ;; *) echo --expect-bad "$bad" ;; esac) 2>&1); rc=$?
  if [ "$want" = pass ]; then
    ok "board-frames --play admits the $n console" "$rc" 0
  else
    ok "board-frames --play refuses the $n console: $want" "$rc|$(printf '%s' "$out" | grep -cF "$want")" "1|1"
  fi
done < "$W/consoles/rows.tsv"

echo "play: 3c. the key sender on the loopback (tools/doom/key-sender.rb against fixtures/play/fake-board.rb)"
P1=$((30000 + $$ % 20000)); P2=$((P1 + 1))
took() { # boot -> "took bad first last session gap" of that boot id's messages
  sed -n "s/^boot $1 took \([0-9]*\) bad \([0-9]*\) first \([0-9]*\) last \([0-9]*\) session \([0-9]*\) gap \([0-9]*\)\$/\1 \2 \3 \4 \5 \6/p" "$W/fake-board.out"
}
# one boot
"$RUBY" "$F/fake-board.rb" "$P1" "$P2" 6 > "$W/fake-board.out" 2>&1 &
fb=$!
"$RUBY" "$ROOT/tools/doom/key-sender.rb" --frames-port "$P1" --keys-port "$P2" --bind 127.0.0.1 --seconds 2 --bad 2 --gap 600 \
  --wait 5 --session 3 --out "$W/sender" > "$W/sender.out" 2>&1
src=$?
wait "$fb"
ok "the sender takes the board's address and boot id from its first frame, and sends 71 messages, 2 of them bad, with one gap" \
   "$src|$(grep -c 'board 127.0.0.1, boot 00000007 (the last of 1), session 00000003; sent 71 to it (bad 2, gaps 1, late 0), 71 in all' "$W/sender.out")" "0|1"
ok "the board took every one, the bad ones with a reserved bit, numbered 1 to 71, with a silence above 600 ms" \
   "$(took 7 | awk '{ print $1, $2, $3, $4, $5, ($6 >= 600 ? "gap" : "no-gap") }')" "71 2 1 71 3 gap"
ok "the sender matched the frames that named its numbers" \
   "$(grep -c 'send to first frame received, over [0-9]* sequence numbers of the last boot' "$W/sender.out")" 1
# a reset 1 s in: the board is a new boot (id 9), and the sender follows it
"$RUBY" "$F/fake-board.rb" "$P1" "$P2" 7 1 > "$W/fake-board.out" 2>&1 &
fb=$!
"$RUBY" "$ROOT/tools/doom/key-sender.rb" --frames-port "$P1" --keys-port "$P2" --bind 127.0.0.1 --seconds 2 --bad 2 --gap 600 \
  --wait 5 --session 3 --out "$W/sender2" > "$W/sender2.out" 2>&1
src=$?
wait "$fb"
ok "after a reset the sender follows the new boot and says which boot was last, with a line per boot" \
   "$src|$(grep -c 'boot 00000009 (the last of 2), session 00000003; sent 71 to it (bad 2, gaps 1, late [0-9]*)' "$W/sender2.out")|$(grep -c '^key-sender: boot 0000000[79]: sent ' "$W/sender2.out")" "0|1|2"
ok "  and at the switch it counts the messages sent to the old boot after its last datagram: the late it names" \
   "$(sed -n 's/^key-sender: switched from boot 00000007 to boot 00000009: \([0-9]*\) message(s) sent to 00000007 after its last datagram arrived$/\1/p' "$W/sender2.out")" \
   "$(sed -n 's/.*(the last of 2).*late \([0-9]*\)).*/\1/p' "$W/sender2.out")"
first7=$(took 7 | cut -d' ' -f3); last7=$(took 7 | cut -d' ' -f4)
second_run_9=$(took 9)
# frames stopped for 0.6 s, the same boot after: the sender stops sending,
# and goes on where it stopped when the frames come back (no gap planted, so
# the board's longest silence is the sender's stop)
"$RUBY" "$F/fake-board.rb" "$P1" "$P2" 6 0 1.5 > "$W/fake-board.out" 2>&1 &
fb=$!
"$RUBY" "$ROOT/tools/doom/key-sender.rb" --frames-port "$P1" --keys-port "$P2" --bind 127.0.0.1 --seconds 2 --bad 2 --gap 0 \
  --wait 5 --session 3 --out "$W/sender3" > "$W/sender3.out" 2>&1
src=$?
wait "$fb"
ok "when the frames stop the sender stops, and goes on where it stopped when they come back" \
   "$src|$(grep -c '^key-sender: boot 00000007: sent 71 (bad 2, gaps 0, paused 1)' "$W/sender3.out")|$(took 7 | awk '{ print $1, $2, $3, $4, ($6 >= 300 ? "silent" : "sent-on") }')" \
   "0|1|71 2 1 71 silent"
ok "the new boot took the whole script from the top, its numbers going on from the old boot's" \
   "$(echo "$second_run_9" | awk -v l="$last7" '{ print $1, $2, ($3 == l + 1 ? "next" : "restart"), $4 - $3, $5, ($6 >= 600 ? "gap" : "no-gap") }')|$first7" \
   "71 2 next 70 3 gap|1"

echo "play: 4. the build for frdm_imxrt1186_cm7"
if [ -z "${SESSION_OBJECTS:-}" ] || [ ! -f "${SESSION_OBJECTS:-}/doom_core_step.o" ] || [ -z "${ZEPHYR_BASE:-}" ]; then
  echo "  SKIP the build: SESSION_OBJECTS or ZEPHYR_BASE is not set" >&2
  skip=1
  summary
fi
rm -rf "$W/board"
"$RUBY" "$TOOL" build --app "$APP" --board frdm_imxrt1186_cm7 --out "$W/board" --net "$F/port0.net" \
  --session-image "$SESSION_IMAGE" --session-objects "$SESSION_OBJECTS" > "$W/board.out" 2>&1
rc=$?
ok "play.rb builds and publishes firmware" "$rc:$([ -f "$W/board/firmware/zephyr.elf" ] && echo elf)" "0:elf"
NM=${NM:-${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/llvm-nm}
ok "its M7 image has the keys channel's get and the frames channel's put" \
   "$("$NM" "$W/board/firmware/zephyr.elf" 2>/dev/null | grep -c -e ' T spc_channel_keys_get$' -e ' T spc_channel_frames_put$')" 2
# the get checks the ring the M33 initialised against its own table of
# geometry words (channel_xcore_in.c.erb): read it from the published object
OBJCOPY=${OBJCOPY:-${LLVM_PREFIX:-/opt/llvm-23.1.1}/bin/llvm-objcopy}
"$OBJCOPY" -O binary --only-section=.rodata.spc_channel_keys_check.want \
  "$W/board/firmware/objects/channel_keys_get.o" "$W/keys_want.bin" 2> "$W/keys_want.err"
# the frames ring: 64 slots of 1312 bytes (4 + 1301, rounded to 32), 83968 B, after the 512-byte header
ok "the M7 checks ring ABI version 5 and the keys ring after the frames ring: depth 16, stride 32, 17 bytes, at 84480" \
   "$("$RUBY" -e 'puts File.binread(ARGV[0]).unpack("L<*").each_slice(2).map { |w, v| "#{w}=#{v}" }.join(" ")' "$W/keys_want.bin" 2>/dev/null)" \
   "0=1196576851 1=5 64=16 65=32 66=17 67=84480"
summary
