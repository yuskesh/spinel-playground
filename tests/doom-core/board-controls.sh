#!/bin/sh
#
# tests/doom-core/board-controls.sh -- the board lane's part 5, without a board.
#
#   [RUBY=ruby] sh tests/doom-core/board-controls.sh [DIR]
#
# tests/doom-core/rt1186.sh judges each demo on the board with
# tests/doom-core/harness/rt1186-board.sh. This drives that same file with a
# planted write (rt_flash) and a planted console (rt_console) in place of the
# board, and the lane's own `ok`, and checks what the lane would conclude:
# its pass and fail counts, and whether it wrote and read at all. Each case
# runs in its own shell with the counters at zero. The recording is the
# first three tics of tests/doom-core/fixtures/screens/DEMO1.tsv and the
# build's id is planted in its build.json.
#
#   with TICS=3 and without TICS (a run that ends after the recording's three
#   tics), each:
#     clean          the build's own console: no failure
#     wrong-frame    tic 1's digests not the recorded ones: one failure, the
#                    frames' check
#     other-build    a console whose SPC_SESSION_ID is another build's: one
#                    failure, though every frame is the recorded one
#     no-identity    a console with no SPC_SESSION_ID: one failure
#   with TICS=3, the build a pair's (decision 0027), its build.json naming
#   the pair id and the companion's id:
#     pair-clean     the M7 prints both, before the first frame: no failure
#     pair-other     the M7 prints another pair id and SPC_PAIR_REFUSED, as
#                    with a companion of another build (the board's run of
#                    --mutate-pair-id): one failure, naming the refusal
#     pair-absent    the M7 found no pair words (SPC_PAIR_REFUSED absent):
#                    one failure
#     pair-silent    the console of a build without a companion, no pair
#                    lines: one failure
#     no-pair        the same console against a build.json without a pair:
#                    no failure (the lane asks for no ids)
#   and, as the M33 prints for the M7 in stage 2 (the M7 has no console):
#     relay-clean    the M33's lines (the M7's session id, the pair's ids,
#                    SPC_M33_SESSION_ID) before the relayed frames: no failure
#     relay-refused  the M33 prints the M7's refusal, SPC_CHANNEL_REFUSED cm7:
#                    one failure, naming it
#     relay-fatal    the M33 prints the M7's fatal error, SPC_M7_FATAL, after
#                    the frames: one failure, naming it
#   and the pair's counts after a drained run (tools/doom/pair-counts.rb), on
#   planted reads of the region's header and the relay's counters and a
#   console of four relayed lines: closed passes; an attempt counted as
#   neither accepted nor refused, a line taken and neither written nor
#   counted, two reads that differ (not drained), and a consumer in FAULT
#   each fail, named; the frames before the run's boot banner (the end of the
#   run the write started) are not counted, and a console without a banner
#   fails, named; and the wait from put to get it reports (decision 0027
#   6, a measurement): line M in microseconds at the consumer's rate with
#   the histogram's bounds, a drift above the alignment's error named void,
#   and no alignment named not measured
#   and, once:
#     write-failed   rt_flash answers 1: one failure, and the console is not
#                    read
#     write-silent   rt_flash answers 0 and its log does not say the write
#                    finished: one failure, and the console is not read
#     reset-failed   the probe could not reset the core (rt_console's .wire
#                    says so) and the console holds an earlier run's frames
#                    with no boot: one failure, and the reset's lines shown
#     no-build-id    build.json without session.id: one failure, nothing
#                    written or read
#     gate           a lane with a failure before part 5: rt1186_board_gate
#                    answers 1 with one more failure
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
RUBY=${RUBY:-ruby}
if [ -n "${1:-}" ]; then CTL=$1; rm -rf "$CTL"; mkdir -p "$CTL" || exit 2
else CTL=$(mktemp -d "${TMPDIR:-/tmp}/board-controls.XXXXXX") || exit 2; trap 'rm -rf "$CTL"' EXIT; fi
T0=$(date +%s)
cpass=0; cfail=0
check() { if [ "$2" = "$3" ]; then echo "  pass $1"; cpass=$((cpass + 1))
          else echo "  FAIL $1 (got '$2', want '$3')"; cfail=$((cfail + 1)); fi; }
ID=0123456789abcdef
OTHER=fedcba9876543210
PAIR=00112233445566aa
COMP=77889900aabbccdd

mkdir -p "$CTL/fix" "$CTL/consoles"
grep -v '^#' "$ROOT/tests/doom-core/fixtures/screens/DEMO1.tsv" | head -3 > "$CTL/fix/DEMO1.tsv"
"$RUBY" -e '
  want = File.readlines(ARGV[0], chomp: true).map { |l| l.split("\t") }
  dir, id, other, pair, comp = ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]
  frame = ->(s) { [0xA5, 0, s.bytesize].pack("C*") + s.b }
  fline = ->(t, v = want[t][1], f = want[t][2]) { frame.(format("F %016x %s %s %016x\n", t, v, f, 40_000_000)) }
  boot = ->(i) { "*** Booting Zephyr OS build v4.4.2 ***\r\n".b + (i ? "SPC_SESSION_ID #{i}\r\n".b : "".b) + "SPC_RUNNING app\r\n".b }
  ended = frame.("D 0000000000000003\n")
  frames = (0..2).map { |t| fline.(t) }.join.b
  wrong = fline.(0) + fline.(1, "0" * 16, "0" * 16) + fline.(2)
  { "clean" => boot.(id) + frames, "wrong-frame" => boot.(id) + wrong,
    "other-build" => boot.(other) + frames, "no-identity" => boot.(nil) + frames }.each do |n, b|
    # with TICS the console is cut inside the next frame; without, the run ends
    File.binwrite(File.join(dir, "#{n}-tics.log"), b + fline.(0)[0, 9])
    File.binwrite(File.join(dir, "#{n}-end.log"), b + ended)
  end
  # the pair lines as main.c prints them, after SPC_SESSION_ID
  pl = ->(p, c, refused = nil) { "SPC_PAIR_ID #{p}\r\nSPC_COMPANION_ID #{c}\r\n".b + (refused ? "SPC_PAIR_REFUSED #{refused}\r\n".b : "".b) }
  boot_p = ->(extra) { "*** Booting Zephyr OS build v4.4.2 ***\r\n".b + "SPC_SESSION_ID #{id}\r\n".b + extra + "SPC_RUNNING app\r\n".b }
  { "pair-clean" => boot_p.(pl.(pair, comp)), "pair-other" => boot_p.(pl.(other, comp, "pair #{other} #{pair}")),
    "pair-absent" => boot_p.("SPC_PAIR_REFUSED absent 00000000\r\n".b), "pair-silent" => boot_p.("".b) }.each do |n, b|
    File.binwrite(File.join(dir, "#{n}-tics.log"), b + frames + fline.(0)[0, 9])
  end
  # stage 2: the M33 prints the M7 lines (main.c.erb, spc_m33_report), its own id last
  m33 = pl.(pair, comp) + "SPC_M33_SESSION_ID #{comp}\r\n".b
  { "relay-clean" => [boot_p.(m33), "".b], "relay-refused" => [boot_p.(m33 + "SPC_CHANNEL_REFUSED cm7 3 90\r\n".b), "".b],
    "relay-fatal" => [boot_p.(m33), "SPC_M7_FATAL 2 0x04101234\r\n".b] }.each do |n, (b, after)|
    File.binwrite(File.join(dir, "#{n}-tics.log"), b + frames + after + fline.(0)[0, 9])
  end' "$CTL/fix/DEMO1.tsv" "$CTL/consoles" "$ID" "$OTHER" "$PAIR" "$COMP" || exit 2

# one case: CONSOLE FLASH(ok|failed|silent) BUILDJSON(id|pair|none) TICS
# -> "pass fail written read" as the lane would count them
run_case() {
  (
    DIR=$CTL/case; FIX=$CTL/fix; RT1186_RES=$DIR/board; TICS=$4
    rm -rf "$DIR"; mkdir -p "$RT1186_RES" "$DIR/fw-DEMO1/firmware"
    : > "$DIR/nor-DEMO1.bin"
    case $3 in
      id) echo "{\"session\": {\"id\": \"$ID\"}}" > "$DIR/fw-DEMO1/firmware/build.json" ;;
      pair) echo "{\"session\": {\"id\": \"$ID\"}, \"pair\": {\"id\": \"$PAIR\", \"primary\": \"$ID\", \"companion\": {\"id\": \"$COMP\"}}}" > "$DIR/fw-DEMO1/firmware/build.json" ;;
      *) echo '{"session": {}}' > "$DIR/fw-DEMO1/firmware/build.json" ;;
    esac
    pass=0; fail=0; written=no; read=no
    ok() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi; }
    # the planted write: its outcome is the case's, not the image's
    rt_flash() {
      written=yes
      case $FLASH in
        ok) echo "Flash Write Done; finished" > "$RT1186_RES/flash_$1.log"; return 0 ;;
        silent) echo "probe not found" > "$RT1186_RES/flash_$1.log"; return 0 ;;
        *) echo "error" > "$RT1186_RES/flash_$1.log"; return 1 ;;
      esac
    }
    rt_console() {
      read=yes
      cp "$CONSOLE" "$RT1186_RES/serial_$1.log"; echo 0 > "$RT1186_RES/serial_$1.reset"
      if [ -n "${WIRE:-}" ]; then printf '%s\nrc=255\n' "$WIRE" > "$RT1186_RES/serial_$1.wire"; fi
    }
    CONSOLE=$1; FLASH=$2
    # shellcheck source=tests/doom-core/harness/rt1186-board.sh
    . "$ROOT/tests/doom-core/harness/rt1186-board.sh"
    rt1186_board_demo DEMO1 240000000 > "$CTL/last.out" 2>&1
    echo "$pass $fail $written $read"
  )
}

echo "board-controls: the board part's judgment, on planted writes and consoles"
for tics in 3 ""; do
  if [ -n "$tics" ]; then sfx=tics; how="TICS=3"; else sfx=end; how="without TICS"; fi
  c=$CTL/consoles
  check "$how, clean: the build's own console passes" "$(run_case "$c/clean-$sfx.log" ok id "$tics")" "2 0 yes yes"
  check "$how, wrong-frame: a frame that is not the recorded one fails the lane" \
        "$(run_case "$c/wrong-frame-$sfx.log" ok id "$tics")" "1 1 yes yes"
  grep -q "tic 1: view 0000000000000000" "$CTL/case/board/frames-DEMO1.out"
  check "  board-frames.rb names tic 1" "$?" 0
  check "$how, other-build: another build's console fails the lane, every frame recorded" \
        "$(run_case "$c/other-build-$sfx.log" ok id "$tics")" "1 1 yes yes"
  check "  board-frames.rb names both builds" \
        "$(grep -c "is build $OTHER, not the build written ($ID)" "$CTL/case/board/frames-DEMO1.out")" 1
  check "$how, no-identity: a console with no SPC_SESSION_ID fails the lane" \
        "$(run_case "$c/no-identity-$sfx.log" ok id "$tics")" "1 1 yes yes"
done
c=$CTL/consoles
check "pair-clean: a pair's console with both ids before the first frame passes" "$(run_case "$c/pair-clean-tics.log" ok pair 3)" "2 0 yes yes"
check "pair-other: the M7 refusing a companion of another build fails the lane" "$(run_case "$c/pair-other-tics.log" ok pair 3)" "1 1 yes yes"
check "  board-frames.rb names the refusal and both pair ids" \
      "$(grep -c "the M7 refused the pair: SPC_PAIR_REFUSED pair $OTHER $PAIR" "$CTL/case/board/frames-DEMO1.out")" 1
check "pair-absent: no pair words fails the lane" "$(run_case "$c/pair-absent-tics.log" ok pair 3)" "1 1 yes yes"
check "  board-frames.rb names it" "$(grep -c 'the M7 refused the pair: SPC_PAIR_REFUSED absent' "$CTL/case/board/frames-DEMO1.out")" 1
check "pair-silent: a console without the pair lines fails a pair's lane" "$(run_case "$c/pair-silent-tics.log" ok pair 3)" "1 1 yes yes"
check "  board-frames.rb names the missing line" "$(grep -c 'printed SPC_PAIR_ID 0 times, not once' "$CTL/case/board/frames-DEMO1.out")" 1
check "no-pair: the same console passes a build without a pair" "$(run_case "$c/pair-silent-tics.log" ok id 3)" "2 0 yes yes"
check "relay-clean: the M33's lines for the M7 before the frames pass" "$(run_case "$c/relay-clean-tics.log" ok pair 3)" "2 0 yes yes"
check "relay-refused: the M7's refusal, printed by the M33, fails the lane" "$(run_case "$c/relay-refused-tics.log" ok pair 3)" "1 1 yes yes"
check "  board-frames.rb names it" "$(grep -c 'the M7 refused the pair: SPC_CHANNEL_REFUSED cm7 3 90' "$CTL/case/board/frames-DEMO1.out")" 1
check "relay-fatal: the M7's fatal error, printed by the M33 after the frames, fails the lane" "$(run_case "$c/relay-fatal-tics.log" ok pair 3)" "1 1 yes yes"
check "  board-frames.rb names it" "$(grep -c 'the M7 stopped on a fatal error: SPC_M7_FATAL 2 0x04101234' "$CTL/case/board/frames-DEMO1.out")" 1
# decision 0027 stage 2: the pair's counts after a drained run (tools/doom/pair-counts.rb),
# on planted header and counter reads and a planted console of four relayed lines
"$RUBY" -e '
  dir = ARGV[0]
  # the header of one channel (ring ABI version 5): 704 bytes, descriptor 0 at line 16, P at 17, C at 18, M at 19, E at 20, F at 21
  hdr = ->(head:, att:, acc:, ref:, tail:, taken:, cstate: 1, fault: 0, init: 0, m: [0, 0, 0, 0, 0, 0xFFFFFFFF, 0, 0], e: [0] * 8,
             f: [0] * 8, notify: 0, rung: 0, woken: 0, lat_max_at: 0, version: 5) do
    w = Array.new(176, 0)
    w[1] = version
    w[16 * 8 + 2] = 0x10201 | (notify << 24)
    w[16 * 8 + 7] = init
    w[17 * 8, 6] = [head, 1, att, acc, ref, rung]
    w[18 * 8, 7] = [tail, cstate, fault, 0, taken, woken, lat_max_at]
    w[19 * 8, 8] = m
    w[20 * 8, 8] = e
    w[21 * 8, 8] = f
    w.pack("V*")
  end
  cnt = ->(held, written, malformed) { [held, written, malformed].pack("V*") }
  frame = ->(s) { [0xA5, 0, s.bytesize].pack("C*") + s.b }
  File.binwrite(File.join(dir, "console.log"), "*** Booting Zephyr OS build v4.4.2 ***\r\n".b + (0..3).map { |t| frame.("F #{t}\n") }.join)
  # the end of the run the write itself started, before the lane reset the board
  # (the 89 frames before DEMO1 banner of 2026-10-26), then the judged run
  File.binwrite(File.join(dir, "console-before.log"), (117..119).map { |t| frame.("F #{t}\n") }.join +
                "*** Booting Zephyr OS build v4.4.2 ***\r\n".b + (0..3).map { |t| frame.("F #{t}\n") }.join)
  File.binwrite(File.join(dir, "console-nobanner.log"), (0..3).map { |t| frame.("F #{t}\n") }.join)
  ok = hdr.(head: 4, att: 6, acc: 4, ref: 2, tail: 4, taken: 4)
  { "closed" => [ok, ok, cnt.(0, 4, 0), cnt.(0, 4, 0)],
    "refused-uncounted" => [hdr.(head: 4, att: 5, acc: 4, ref: 2, tail: 4, taken: 4)] * 2 + [cnt.(0, 4, 0)] * 2,
    "lost" => [hdr.(head: 4, att: 6, acc: 4, ref: 2, tail: 4, taken: 4)] * 2 + [cnt.(0, 3, 0)] * 2,
    "moving" => [hdr.(head: 3, att: 5, acc: 3, ref: 2, tail: 3, taken: 3), ok, cnt.(0, 4, 0), cnt.(0, 4, 0)],
    "fault" => [hdr.(head: 4, att: 6, acc: 4, ref: 2, tail: 4, taken: 4, cstate: 3, fault: 2)] * 2 + [cnt.(0, 4, 0)] * 2,
    # decision 0028: a doorbell (notify 0x01), 3 rings of 4 accepted, 3 wake-ups
    "bell" => [hdr.(head: 4, att: 6, acc: 4, ref: 2, tail: 4, taken: 4, notify: 1, rung: 3, woken: 3)] * 2 + [cnt.(0, 4, 0)] * 2 }.each do |n, (a, b, c, d)|
    File.binwrite(File.join(dir, "#{n}.h1"), a); File.binwrite(File.join(dir, "#{n}.h2"), b)
    File.binwrite(File.join(dir, "#{n}.c1"), c); File.binwrite(File.join(dir, "#{n}.c2"), d)
  end
  # line M (decision 0027 6): n 4, min 240, max 2400, sum 4800 consumer cycles, the alignment
  # 120 either side, the longest poll gap 480; at 240 MHz 1, 5 and 10 us, 0.5 and 2 us
  m = [4, 240, 2400, 4800, 0, 120, 480, 0]
  # line E (decision 0028 Q5): 3 rounds; the shortest trip 240 cycles (1 us) departing -480
  # (-2 us) at round 1, the last 480 (2 us) departing 1200 (5 us) at round 3, the longest 720
  e = [3, 240, (-480) & 0xFFFFFFFF, 1, 480, 1200, 3, 720]
  # line F (version 5): 2 rounds timed out; g 24 cycles (0.1 us) at the round of the shortest trip, 48 (0.2 us)
  # at the last, 96 the largest; from t1 the shortest departs in [-2.5, -2.4] us, the last in [4.0, 4.2]
  f = [2, 24, 48, 96, 0, 0, 0, 0]
  # line C: message 2 (init_index 0) had the longest wait
  { "wait" => [m, [0] * 8, [0] * 8, 0, 5], "wait-void" => [m[0, 7] + [300], [0] * 8, [0] * 8, 0, 5],
    "wait-none" => [[0, 0, 0, 0, 0, 0xFFFFFFFF, 0, 0], [0] * 8, [0] * 8, 0, 5],
    "wait-estimate" => [m, e, f, 2, 5], "wait-v4" => [m, e, f, 2, 4], "wait-spare" => [m, e, f[0, 7] + [1], 2, 5] }.each do |n, (mm, ee, ff, at, ver)|
    h = hdr.(head: 4, att: 4, acc: 4, ref: 0, tail: 4, taken: 4, m: mm, e: ee, f: ff, lat_max_at: at, version: ver)
    File.binwrite(File.join(dir, "#{n}.h1"), h); File.binwrite(File.join(dir, "#{n}.h2"), h)
    File.binwrite(File.join(dir, "#{n}.c1"), cnt.(0, 4, 0)); File.binwrite(File.join(dir, "#{n}.c2"), cnt.(0, 4, 0))
  end
  # the histogram: two waits in bucket 7 (128..255 cycles), two in bucket 11 (2048..4095)
  hist = Array.new(32, 0); hist[7] = 2; hist[11] = 2
  File.binwrite(File.join(dir, "wait.hist"), hist.pack("V*"))' "$CTL/consoles" || exit 2
counts() { "$RUBY" "$ROOT/tools/doom/pair-counts.rb" --header "$CTL/consoles/$1.h1,$CTL/consoles/$1.h2" --counters "$CTL/consoles/$1.c1,$CTL/consoles/$1.c2" \
             --console "$CTL/consoles/console.log" > "$CTL/counts-$1.out" 2>&1; echo $?; }
check "counts closed: a drained run whose four equations hold passes" "$(counts closed)" 0
check "counts before-banner: the earlier run's frames before the banner are not the run's; its four frames close" \
      "$("$RUBY" "$ROOT/tools/doom/pair-counts.rb" --header "$CTL/consoles/closed.h1,$CTL/consoles/closed.h2" --counters "$CTL/consoles/closed.c1,$CTL/consoles/closed.c2" \
           --console "$CTL/consoles/console-before.log" > "$CTL/counts-before.out" 2>&1; echo $?):$(grep -c 'frames on the console = written: 4 = 4, 4' "$CTL/counts-before.out")" "0:1"
check "counts no-banner: a console with no boot banner after the reset fails, named" \
      "$("$RUBY" "$ROOT/tools/doom/pair-counts.rb" --header "$CTL/consoles/closed.h1,$CTL/consoles/closed.h2" --counters "$CTL/consoles/closed.c1,$CTL/consoles/closed.c2" \
           --console "$CTL/consoles/console-nobanner.log" > "$CTL/counts-nobanner.out" 2>&1; echo $?):$(grep -c 'FAIL the console holds no boot banner after the lane.s reset' "$CTL/counts-nobanner.out")" "1:1"
check "counts refused-uncounted: attempted is not accepted + refused, named" "$(counts refused-uncounted):$(grep -c 'FAIL attempted = accepted + refused does not close (6 != 5)' "$CTL/counts-refused-uncounted.out")" "1:1"
check "counts lost: a line taken and neither written nor counted, named" "$(counts lost):$(grep -c 'FAIL taken = written + malformed + held does not close (3 != 4)' "$CTL/counts-lost.out"):$(grep -c 'FAIL frames on the console = written does not close (4 != 3)' "$CTL/counts-lost.out")" "1:1:1"
check "counts moving: two reads that differ are not a drained run" "$(counts moving):$(grep -c 'FAIL the run is not drained' "$CTL/counts-moving.out")" "1:1"
check "counts bell: a doorbell's channel closes as any and reports notify, rung and woken; a polled one reports none" \
      "$(counts bell):$(grep -c 'doorbell: notify 0x01 (MU1, GIR0), rung 3 of 4 accepted, woken 3$' "$CTL/counts-bell.out"):$(grep -c 'doorbell:' "$CTL/counts-closed.out")" "0:1:0"
check "counts fault: a consumer in FAULT fails, named" "$(counts fault):$(grep -c 'FAIL the consumer is not taking (state 3, fault 2)' "$CTL/counts-fault.out")" "1:1"
check "counts moving, not judged (a TICS run): the same findings are info, none FAIL, and the exit is 0" \
      "$("$RUBY" "$ROOT/tools/doom/pair-counts.rb" --header "$CTL/consoles/moving.h1,$CTL/consoles/moving.h2" --counters "$CTL/consoles/moving.c1,$CTL/consoles/moving.c2" \
           --console "$CTL/consoles/console.log" --not-judged > "$CTL/counts-moving-nj.out" 2>&1; echo $?):$(grep -c 'info (not judged in a TICS run) the run is not drained' "$CTL/counts-moving-nj.out"):$(grep -c FAIL "$CTL/counts-moving-nj.out")" "0:1:0"
waits() { "$RUBY" "$ROOT/tools/doom/pair-counts.rb" --header "$CTL/consoles/$1.h1,$CTL/consoles/$1.h2" --counters "$CTL/consoles/$1.c1,$CTL/consoles/$1.c2" \
            --console "$CTL/consoles/console.log" --consumer-hz 240000000 --hist "$CTL/consoles/wait.hist" --wait-json "$CTL/$1.json" > "$CTL/counts-$1.out" 2>&1; echo $?; }
check "wait: line M in microseconds at the consumer's rate, the histogram's median and 99th percentile bounds, RC24M named; no verdict" \
      "$(waits wait):$(grep -c 'wait console: n=4 min=1.0 mean=5.0 max=10.0 us p50<=1.063 p99<=17.063 us poll_max=2.0 us sync_err=+-0.5 us drift: none seen above the rounds. own error; DWT CYCCNT of each core from RC24M; the consumer at 240000000 Hz$' "$CTL/counts-wait.out"):$("$RUBY" -rjson -e 'j = JSON.parse(File.read(ARGV[0])); puts [j["n"], j["void"]].join(",")' "$CTL/wait.json")" \
      "0:1:4,false"
check "wait-void: a drift above the alignment's error voids the figures, named" "$(waits wait-void):$(grep -c 'drift >= 1.25 us; .*; VOID: the drift is above the alignment.s error$' "$CTL/counts-wait-void.out")" "0:1"
check "wait-estimate: lines E and F print each round's departure from the midpoint, +- its half trip, and from t1, in [dev - trip/2, + g]; the timeouts" \
      "$(waits wait-estimate):$(grep -c "drift estimate console: 3 rounds, 2 timed out; the shortest trip's departure -2.0 +- 0.5 us, from t1 in \[-2.5, -2.4\] us, at 1 s; the last round's 5.0 +- 1.0 us, from t1 in \[4.0, 4.2\] us, at 3 s; the longest trip 3.0 us, the largest g 0.4 us$" "$CTL/counts-wait-estimate.out"):$(grep -c 'drift estimate' "$CTL/counts-wait.out")" "0:1:0"
check "wait-estimate: line C names the message whose wait was the longest" \
      "$(grep -c 'longest wait console: message 2 of 4 accepted (0 is the first put), 10.0 us$' "$CTL/counts-wait-estimate.out")" 1
check "wait-v4: a version 4 header is refused by this reader, named, exit 2" \
      "$(waits wait-v4):$(grep -c 'wait-v4.h1: the header is ring ABI version 4; this tool reads version 5$' "$CTL/counts-wait-v4.out"):$(grep -c 'drift estimate\|longest wait' "$CTL/counts-wait-v4.out")" "2:1:0"
check "wait-spare: line F's spare words not 0 are refused, named, exit 2" \
      "$(waits wait-spare):$(grep -c "line F's words 4 to 7 are not 0 (0 0 0 1)$" "$CTL/counts-wait-spare.out")" "2:1"
check "wait-none: without an alignment the wait is not measured, named" "$(waits wait-none):$(grep -c 'wait console: not measured, no alignment (sync_err 0xFFFFFFFF)$' "$CTL/counts-wait-none.out")" "0:1"
# rt_gdb_read (tests/doom-core/harness/rt1186-gdb.sh) without a board: ssh
# answers as a listening server, and a gdb that writes nothing (a read that
# failed) or writes each dump; a file an earlier demo's read left must not
# pass for this one's
mkdir -p "$CTL/gdb/bin" "$CTL/gdb/res"
printf '#!/bin/sh\necho "listening on port 3333"\n' > "$CTL/gdb/bin/ssh"
printf '#!/bin/sh\n# the gdb that writes nothing: a read that failed\nexit 0\n' > "$CTL/gdb/bin/gdb-none"
cat > "$CTL/gdb/bin/gdb-dump" <<'G'
#!/bin/sh
# the gdb that writes each `dump binary memory FILE FROM TO` it is given
for a in "$@"; do
  case $a in "dump binary memory "*) set -- $a; head -c $(($6 - $5)) /dev/zero > "$4" ;; esac
done
G
chmod +x "$CTL/gdb/bin/ssh" "$CTL/gdb/bin/gdb-none" "$CTL/gdb/bin/gdb-dump"
gdbread() { # gdb -> "rc|message|size of the file after the read"
  (
    PATH=$CTL/gdb/bin:$PATH; RT1186_RES=$CTL/gdb/res; RT1186_HOST=planted; RT1186_PROBE=planted; RT1186_LINKSERVER=LinkServer; RT1186_DEVICE=planted
    rt_q() { printf "'%s'" "$1"; }
    rt_rsh() { :; }
    . "$ROOT/tests/doom-core/harness/rt1186-gdb.sh"
    RT1186_GDB=$CTL/gdb/bin/$1
    # the earlier demo's file, the right size, still there
    head -c 52 /dev/zero > "$RT1186_RES/net1-DEMO2.bin"
    m=$(RT1186_GDB_TAG=DEMO2 rt_gdb_read "$RT1186_RES/net1-DEMO2.bin" 0x30000000 52 2>&1); rc=$?
    echo "$rc|$m|$([ -f "$RT1186_RES/net1-DEMO2.bin" ] && wc -c < "$RT1186_RES/net1-DEMO2.bin" | tr -d ' ')"
  )
}
r=$(gdbread gdb-none)
check "gdb-stale: a read that writes nothing does not pass on an earlier demo's file, which is gone, and names it" \
      "$(echo "$r" | cut -d'|' -f1):$(echo "$r" | grep -c "the read wrote no $CTL/gdb/res/net1-DEMO2.bin (see $CTL/gdb/res/gdb-DEMO2.log)"):$(echo "$r" | cut -d'|' -f3)" "1:1:"
r=$(gdbread gdb-dump)
check "  and a read that writes it passes, the logs named for the demo" \
      "$(echo "$r" | cut -d'|' -f1,3):$([ -f "$CTL/gdb/res/gdb-DEMO2.log" ] && [ -f "$CTL/gdb/res/gdbserver-DEMO2.log" ] && echo logs)" "0|52:logs"
# the probe still held by an earlier read's server (rt_gdb_idle answers 1), and
# a server that never says it listens: each read fails, named, and runs no gdb
printf '#!/bin/sh\n# the server that never listens\nexit 0\n' > "$CTL/gdb/bin/ssh-silent"
chmod +x "$CTL/gdb/bin/ssh-silent"
gdbheld() { # busy|silent -> "rc|message|the file"
  (
    PATH=$CTL/gdb/bin:$PATH; RT1186_RES=$CTL/gdb/res; RT1186_HOST=planted; RT1186_PROBE=planted; RT1186_LINKSERVER=LinkServer; RT1186_DEVICE=planted
    rt_q() { printf "'%s'" "$1"; }
    if [ "$1" = busy ]; then
      rt_rsh() { case $1 in *pgrep*) echo "a gdbserver of probe planted still runs after 20 s"; return 1 ;; esac; }
    else
      rt_rsh() { :; }
      mkdir -p "$CTL/gdb/silent"; ln -sf "$CTL/gdb/bin/ssh-silent" "$CTL/gdb/silent/ssh"; PATH=$CTL/gdb/silent:$PATH; RT1186_GDB_LISTEN=1
    fi
    . "$ROOT/tests/doom-core/harness/rt1186-gdb.sh"
    RT1186_GDB=$CTL/gdb/bin/gdb-dump
    m=$(rt_gdb_read "$RT1186_RES/held-$1.bin" 0x30000000 52 2>&1); rc=$?
    echo "$rc|$m|$([ -f "$RT1186_RES/held-$1.bin" ] && echo written || echo none)"
  )
}
r=$(gdbheld busy)
check "gdb-held: a probe an earlier server still holds fails the read, named, and no gdb runs" \
      "$(echo "$r" | cut -d'|' -f1):$(echo "$r" | grep -c 'a gdbserver of probe planted still runs after 20 s'):$(echo "$r" | cut -d'|' -f3)" "1:1:none"
r=$(gdbheld silent)
check "gdb-silent: a server that never says it listens fails the read, named, and no gdb runs" \
      "$(echo "$r" | cut -d'|' -f1):$(echo "$r" | grep -c 'the gdbserver did not listen within 1 s'):$(echo "$r" | cut -d'|' -f3)" "1:1:none"
check "write-failed: one failure, and the console is not read" "$(run_case "$CTL/consoles/clean-tics.log" failed id 3)" "0 1 yes no"
check "write-silent: a write whose log does not say it finished fails, and the console is not read" \
      "$(run_case "$CTL/consoles/clean-tics.log" silent id 3)" "0 1 yes no"
tail -c +$(( $(grep -a -b -o 'F ' "$CTL/consoles/clean-tics.log" | head -1 | cut -d: -f1) - 1 )) "$CTL/consoles/clean-tics.log" > "$CTL/consoles/reset-failed.log"
check "reset-failed's input: frames and no boot" \
      "$(grep -a -c 'Booting Zephyr' "$CTL/consoles/reset-failed.log"):$(grep -a -c 'F ' "$CTL/consoles/reset-failed.log")" "0:4"
check "reset-failed: a reset that failed leaves no boot to read, and fails the lane" \
      "$(WIRE='ERRMSG: Exception: No probes detected' run_case "$CTL/consoles/reset-failed.log" ok id 3)" "1 1 yes yes"
check "  the board part shows the reset's own lines" \
      "$(grep -c '^  the reset: ERRMSG: Exception: No probes detected$' "$CTL/last.out"):$(grep -c '^  the reset: rc=255$' "$CTL/last.out")" "1:1"
check "no-build-id: nothing is written or read" "$(run_case "$CTL/consoles/clean-tics.log" ok none 3)" "0 1 no no"
check "gate: a lane with a failure before part 5 is stopped there, with one more failure" \
      "$( pass=0; fail=2
          ok() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi; }
          . "$ROOT/tests/doom-core/harness/rt1186-board.sh"
          rt1186_board_gate > /dev/null; echo "$? $fail" )" "1 3"
check "  and a lane with none passes it" \
      "$( fail=0; . "$ROOT/tests/doom-core/harness/rt1186-board.sh"; rt1186_board_gate; echo "$? $fail" )" "0 0"

echo "board-controls: $((cpass + cfail)) checked, $cpass pass, $cfail fail; $(( $(date +%s) - T0 )) s"
[ "$cfail" = 0 ]
