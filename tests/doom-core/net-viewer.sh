#!/bin/sh
#
# tests/doom-core/net-viewer.sh -- tools/doom/net-viewer.rb on planted datagrams.
#
#   [RUBY=ruby] [CC=cc] sh tests/doom-core/net-viewer.sh DIR
#
# Decision 0024's viewer, with no board and no network: the datagrams are a
# recording planted here (net-viewer.rb --replay reads the form --record
# writes), and the console is a planted log in the board's own framing (0014
# frames on channel 0). The screens are synthetic: six tics of a pattern
# that differs per tic, and a palette. The console's `F` lines carry digests
# computed by the board's own provider, examples/doom/core/board/
# frame_digests.c, compiled here for the host; the viewer's must equal them.
#
# WHAT IT CHECKS (wire version 3, decision 0025 point 15)
#   * FNV-1a 64's published vectors ("" and "a") through NetFrames.fnv1a64,
#     and frame_digests.c's line for one screen equal to the viewer's
#   * a run with drops, boot 1234abcd: tic 1 has a piece twice, tic 2 lacks
#     one piece, tic 3's pieces come in reverse order, tic 4 is not sent (the
#     board's choice); S arrives. The console writes F for tics 0 and 1
#     before its B line, and N says 0 dropped, 1 not sent. The summary counts
#     4 complete, 1 incomplete (1 piece), 1 absent, 1 duplicate; the 4
#     complete frames match; 2 frames missing, so the network lost 1; with
#     --max-loss 1 the exit status is 0; --log has one row per closed frame
#   * that run without --max-loss, whose default is 0: exit 1, the loss named
#   * the first Clarification's two-count N reads as 0 not sent
#   * two boots interleaved piece by piece, each three frames of its own
#     screens: never combined; each console's boot matches 3 frames, the
#     other boot is named as not judged
#   * a late viewer: frames before any palette are digested, counted as
#     before the palette and not shown; a second, different palette replaces
#     the first, and the frame after it is shown in the second's colours
#   * --window: a piece of tic 0 after a piece of tic 10 (window 8) closes
#     tic 0 incomplete, and the piece is counted late
#   * the input each frame carries: the run with drops carries none (as the
#     demo application's frames do); a run of frames with none, held twice
#     and released by the time-out is counted so, and a frame whose 50
#     pieces disagree on the sequence (one piece) is closed incomplete with
#     no piece missing, its --log row `mismatch`
#   * failing controls, each exit 1 and named (with --max-loss 1, so that the
#     network loss the run also has is not what fails it):
#       one F line's full digest changed            -> 1 differ, its tic
#       one screen byte flipped in tic 1's piece     -> 1 differ, tic 1
#       a piece with boot id 0, one of version 1,
#         one of an unknown kind                     -> 3 bad, each reason
#       the run with drops in version 2, 0024's wire -> every datagram bad,
#                                                       version 2; no boot
#       a piece of input state 3, one of state 0 with
#         a session, one of state 1 with session 0   -> 3 bad, each reason
#       a T (0x54, the M33's report 0024 abolished),
#         of its former 18 bytes, alone              -> 1 bad, kind 0x54
#       a piece of tic 3 after tic 20 (window 8)     -> backwards, tic 3
#       an S whose counts do not add up              -> named
#       a console without B, with two B, or naming
#         a boot that sent nothing                   -> each named
#       no datagram at all, against the console      -> no frame matched
#   * --ppm-dir with --aspect 4:3 --scale 1 writes a 320x240 P6 whose first
#     pixel is the palette's colour for the screen's first byte
#   * a recording cut inside a datagram is a usage error (2)
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIR=${1:?usage: net-viewer.sh DIR}
RUBY=${RUBY:-ruby}
CC=${CC:-cc}
VIEWER=$ROOT/tools/doom/net-viewer.rb
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
T0=$(date +%s)
mkdir -p "$DIR" || exit 2

# the board's digest provider, for the host
cat > "$DIR/digests.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
void spc_app_frame_digests(const uint8_t *, uint32_t, uint32_t, uint8_t *, uint32_t);
int main(int argc, char **argv)
{
	static uint8_t screen[64000];
	uint8_t out[33];
	for (int i = 1; i < argc; i++) {
		FILE *f = fopen(argv[i], "rb");
		if (!f || fread(screen, 1, sizeof screen, f) != sizeof screen)
			return 2;
		fclose(f);
		spc_app_frame_digests(screen, sizeof screen, 53760, out, sizeof out);
		printf("%.33s\n", out);
	}
	return 0;
}
EOF
"$CC" -O1 -o "$DIR/digests" "$DIR/digests.c" "$ROOT/examples/doom/core/board/frame_digests.c" || {
  echo "net-viewer: FAIL cannot build frame_digests.c with $CC"; exit 1; }

# The screens and the palette; the datagrams of each case; the consoles.
"$RUBY" -e '
  dir = ARGV[0]
  screens = (0..5).map { |t| Array.new(64_000) { |i| ((i % 320) * 7 + (i / 320) * 13 + t * 29) & 0xff }.pack("C*") }
  screens.each_with_index { |s, t| File.binwrite(File.join(dir, "screen#{t}.bin"), s) }
  File.binwrite(File.join(dir, "palette.bin"), Array.new(768) { |i| (i * 37 + 11) & 0xff }.pack("C*"))
' "$DIR" || exit 1
"$DIR/digests" "$DIR"/screen0.bin "$DIR"/screen1.bin "$DIR"/screen2.bin "$DIR"/screen3.bin \
  "$DIR"/screen4.bin "$DIR"/screen5.bin > "$DIR/board-digests.txt" || { echo "net-viewer: FAIL digests"; exit 1; }

"$RUBY" -I"$ROOT/tools/doom" -rnet_frames -e '
  dir = ARGV[0]
  screens = (0..5).map { |t| File.binread(File.join(dir, "screen#{t}.bin")) }
  palette = File.binread(File.join(dir, "palette.bin"))
  other = palette.bytes.map { |c| c ^ 0x5a }.pack("C*")
  board = File.readlines(File.join(dir, "board-digests.txt"), chomp: true).map(&:split)
  a = 0x1234abcd
  b = 0x0badf00d
  hdr = ->(kind, boot, version = 3) { [kind, version, boot].pack("CCL<") }
  # the pieces of a frame, each with the input of the tic: session, sequence, state
  pieces = ->(boot, t, s, input = [0, 0, 0]) {
    (0...50).map { |k| hdr.(0x43, boot) + [t, k, 50, *input].pack("L<CCL<L<C") + s.byteslice(k * 1280, 1280) }
  }
  pal = ->(boot, rgb = palette) { hdr.(0x50, boot) + rgb }
  stream = ->(boot, *n) { hdr.(0x53, boot) + n.pack("L<5") }
  # T, the M33 report of the first draft of version 2, which 0024 abolished
  transport = ->(boot, *n) { hdr.(0x54, boot) + n.pack("L<3") }
  rec = ->(name, dgrams) { File.open(File.join(dir, name), "wb") { |io| dgrams.each { |d| NetFrames::Recording.write(io, d) } } }
  drops = [pal.(a)]
  drops += pieces.(a, 0, screens[0])
  p1 = pieces.(a, 1, screens[1]); drops += p1[0, 10] + [p1[9]] + p1[10..]
  p2 = pieces.(a, 2, screens[2]); drops += p2.reject.with_index { |_, k| k == 17 }
  drops += pieces.(a, 3, screens[3]).reverse
  drops += pieces.(a, 5, screens[5])
  drops += [stream.(a, 5, 5, 1, 0, 0)]
  rec.("drops.rec", drops)
  flipped = drops.map(&:dup)
  i = flipped.index { |d| d.getbyte(0) == 0x43 && d.unpack("@6L<C") == [1, 3] }
  flipped[i].setbyte(NetFrames::PIECE_HEADER + 88, flipped[i].getbyte(NetFrames::PIECE_HEADER + 88) ^ 1)
  rec.("flipped.rec", flipped)
  rec.("bad.rec", drops + [pieces.(0, 6, screens[0])[0], pieces.(a, 6, screens[0])[0].dup.tap { |d| d.setbyte(1, 1) },
                           hdr.(0x51, a) + "x" * 20])
  rec.("transport.rec", drops + [transport.(a, 252, 0, 2)])
  rec.("v2.rec", drops.map { |d| d.dup.tap { |x| x.setbyte(1, 2) } })
  rec.("badinput.rec", drops + [pieces.(a, 6, screens[0], [0x5e55, 7, 3])[0], pieces.(a, 6, screens[0], [0x5e55, 0, 0])[1],
                                pieces.(a, 6, screens[0], [0, 7, 1])[2]])
  held = [0x5e55, 7, 1]
  mixed = pieces.(a, 4, screens[4], held)
  mixed[9] = pieces.(a, 4, screens[4], [0x5e55, 8, 1])[9]
  rec.("input.rec", [pal.(a)] + pieces.(a, 0, screens[0]) + pieces.(a, 1, screens[1], held) + pieces.(a, 2, screens[2], held) +
                    pieces.(a, 3, screens[3], [0x5e55, 7, 2]) + mixed + pieces.(a, 5, screens[5], [0x5e55, 9, 1]))
  rec.("inconsistent.rec", drops + [stream.(a, 5, 5, 0, 0, 0)])
  rec.("backwards.rec", [pal.(a)] + pieces.(a, 20, screens[0]) + [pieces.(a, 3, screens[1])[0]])
  two = [pal.(a), pal.(b)]
  (0..2).each { |t| two += pieces.(a, t, screens[t]).zip(pieces.(b, t, screens[t + 3])).flatten }
  rec.("two.rec", two)
  rec.("lateview.rec", pieces.(a, 3, screens[3]) + [pal.(a)] + pieces.(a, 4, screens[4]) + [pal.(a, other)] + pieces.(a, 5, screens[5]))
  File.binwrite(File.join(dir, "other.bin"), other)
  window = [pal.(a)] + pieces.(a, 0, screens[0])[0, 49] + pieces.(a, 10, screens[0]) + [pieces.(a, 0, screens[0])[49]]
  rec.("window.rec", window)
  rec.("one.rec", [pal.(a)] + pieces.(a, 0, screens[0]))
  rec.("empty.rec", [])
  File.binwrite(File.join(dir, "cut.rec"), File.binread(File.join(dir, "one.rec"))[0, 2000])
  frame = ->(line) { [0xA5, 0, line.bytesize].pack("C3") + line }
  hex = ->(n) { format("%016x", n) }
  # F lines for the tics given, B after the first `before` of them (nil: no
  # B; an array: one B per id), then N and D
  log = ->(name, digests, boots: [a], before: 2, n: [0, 0, 1], tics: digests.size) {
    body = "*** Booting Zephyr OS build v4.4.2 ***\r\nSPC_SESSION_ID 0123456789abcdef\r\n".b
    digests.each_with_index do |(v, f), t|
      boots.each { |id| body << frame.("B #{hex.(id)}\n") } if t == before
      body << frame.("F #{hex.(t)} #{v} #{f} #{hex.(1000 + t)}\n")
    end
    body << frame.("N #{n.map { |x| hex.(x) }.join(" ")}\n") << frame.("D #{hex.(tics)}\n")
    File.binwrite(File.join(dir, name), body)
  }
  log.("console.log", board)
  log.("n2.log", board, n: [0, 0])
  changed = board.map(&:dup); changed[3][1] = changed[3][1].tr("0-9a-f", "1-9a-f0")
  log.("changed.log", changed)
  log.("twoA.log", board[0, 3], n: [0, 0, 0], before: 0)
  log.("twoB.log", board[3, 3], boots: [b], n: [0, 0, 0], before: 0)
  log.("noB.log", board, boots: [])
  log.("twoBlines.log", board, boots: [a, b])
  log.("otherB.log", board, boots: [0x77777777])
  # one screen through the viewer library, for the provider check
  File.write(File.join(dir, "lib-digests.txt"), NetFrames.digests(screens[0]).join(" ") + "\n")
' "$DIR" || exit 1

echo "== FNV-1a 64 and the board's provider"
ok "fnv1a64(\"\") is the published vector" \
   "$("$RUBY" -I"$ROOT/tools/doom" -rnet_frames -e 'print NetFrames.fnv1a64("")')" cbf29ce484222325
ok "fnv1a64(\"a\") is the published vector" \
   "$("$RUBY" -I"$ROOT/tools/doom" -rnet_frames -e 'print NetFrames.fnv1a64("a")')" af63dc4c8601ec8c
ok "the viewer's digests of screen 0 are frame_digests.c's line" \
   "$(cat "$DIR/lib-digests.txt")" "$(head -1 "$DIR/board-digests.txt")"

echo "== a run with drops, against its console"
"$RUBY" "$VIEWER" --replay "$DIR/drops.rec" --console "$DIR/console.log" --max-loss 1 --log "$DIR/drops.tsv" > "$DIR/drops.out" 2>&1
ok "exit status 0" "$?" 0
ok "one boot" "$(grep -c 'datagram(s), 0 bad; 1 boot(s)$' "$DIR/drops.out")" 1
ok "frames counted" "$(grep -c 'boot 1234abcd: .*palette received (1 time(s)); frames: 4 complete (0 before the palette), 1 incomplete (1 piece(s) missing), 1 absent; 0 late, 1 duplicate, 0 backwards' "$DIR/drops.out")" 1
ok "S reported" "$(grep -c "the M7's latest S: tic 5, 5 sent, 1 not sent, 0 dropped" "$DIR/drops.out")" 1
ok "4 complete frames match, F lines before B included" "$(grep -c "6 F line(s) (boot 1234abcd): 4 match, 0 differ, 0 complete frame(s) with no F line" "$DIR/drops.out")" 1
ok "missing frames against the board's N line" \
   "$(grep -c '2 frame(s) missing here; the board dropped 0 frame(s) (0 message(s)) and did not send 1 by choice, so the network lost 1' "$DIR/drops.out")" 1
ok "--log rows" "$(grep -v '^#' "$DIR/drops.tsv" | cut -f1,2,5 | tr '\t\n' ':,')" \
   "1234abcd:0:match,1234abcd:1:match,1234abcd:2:incomplete:1,1234abcd:3:match,1234abcd:5:match,"

"$RUBY" "$VIEWER" --replay "$DIR/drops.rec" --console "$DIR/console.log" > "$DIR/maxloss.out" 2>&1
ok "--max-loss by default 0: exit status 1" "$?" 1
ok "--max-loss by default 0: the loss named" \
   "$(grep -c '^net-viewer: FAIL the network lost 1 frame(s), more than --max-loss 0$' "$DIR/maxloss.out")" 1
"$RUBY" "$VIEWER" --replay "$DIR/drops.rec" --console "$DIR/n2.log" --max-loss 2 > "$DIR/n2.out" 2>&1
ok "a two-count N: exit status 0, nothing not sent, so the network lost 2" \
   "$?:$(grep -c 'did not send 0 by choice, so the network lost 2$' "$DIR/n2.out")" "0:1"

echo "== boots"
"$RUBY" "$VIEWER" --replay "$DIR/two.rec" --console "$DIR/twoA.log" > "$DIR/twoA.out" 2>&1
ok "two boots interleaved, judged as A: exit status 0" "$?" 0
ok "  each boot its own 3 frames" "$(grep -c 'frames: 3 complete (0 before the palette), 0 incomplete' "$DIR/twoA.out")" 2
ok "  A's console matches 3, B not judged" \
   "$(grep -c '(boot 1234abcd): 3 match, 0 differ' "$DIR/twoA.out"):$(grep -c 'not judged, not the console.s boot: 0badf00d$' "$DIR/twoA.out")" "1:1"
"$RUBY" "$VIEWER" --replay "$DIR/two.rec" --console "$DIR/twoB.log" > "$DIR/twoB.out" 2>&1
ok "  the same stream judged as B: exit status 0, 3 match" "$?:$(grep -c '(boot 0badf00d): 3 match, 0 differ' "$DIR/twoB.out")" "0:1"
"$RUBY" "$VIEWER" --replay "$DIR/lateview.rec" --ppm-dir "$DIR/lateppm" --scale 1 > "$DIR/lateview.out" 2>&1
ok "a late viewer: exit status 0" "$?" 0
ok "  3 complete, 1 before the palette; two palettes, one change" \
   "$(grep -c 'palette received (2 time(s), 1 changed); frames: 3 complete (1 before the palette)' "$DIR/lateview.out")" 1
ok "  the frame before the palette not shown, the last one in the second palette's colours" \
   "$([ -e "$DIR/lateppm/tic000003.ppm" ] && echo shown || echo not):$("$RUBY" -e '
      img = File.binread(ARGV[0]); pal = File.binread(ARGV[1]); s = File.binread(ARGV[2]); head = "P6\n320 200\n255\n"
      print img.byteslice(head.bytesize, 3) == pal.byteslice(3 * s.getbyte(0), 3) ? "second" : "other"
    ' "$DIR/lateppm/tic000005.ppm" "$DIR/other.bin" "$DIR/screen5.bin")" "not:second"

echo "== the window"
"$RUBY" "$VIEWER" --replay "$DIR/window.rec" --window 8 > "$DIR/window.out" 2>&1
ok "a piece after the window: tic 0 incomplete, the piece late" \
   "$(grep -c '1 complete (0 before the palette), 1 incomplete (1 piece(s) missing), 9 absent; 1 late, 0 duplicate, 0 backwards' "$DIR/window.out")" 1

echo "== the input"
ok "the run with drops carries no input" \
   "$(grep -c 'boot 1234abcd: input of the complete frames: 4 none, 0 held, 0 released by the time-out; 0 incomplete' "$DIR/drops.out")" 1
"$RUBY" "$VIEWER" --replay "$DIR/input.rec" --log "$DIR/input.tsv" > "$DIR/input.out" 2>&1
ok "none, held, released: exit status 0" "$?" 0
ok "  counted by state; the frame whose pieces disagree is incomplete" \
   "$(grep -c 'boot 1234abcd: input of the complete frames: 1 none, 3 held, 1 released by the time-out; 1 incomplete frame(s) whose pieces disagree on it$' "$DIR/input.out")" 1
ok "  no piece missing for it" "$(grep -c 'frames: 5 complete (0 before the palette), 1 incomplete (0 piece(s) missing), 0 absent' "$DIR/input.out")" 1
ok "  its --log row" "$(grep -v '^#' "$DIR/input.tsv" | cut -f2,5 | tr '\t\n' ':,')" \
   "0:complete,1:complete,2:complete,3:complete,4:mismatch,5:complete,"

echo "== failing controls"
"$RUBY" "$VIEWER" --replay "$DIR/drops.rec" --console "$DIR/changed.log" --max-loss 1 > "$DIR/changed.out" 2>&1
ok "an F line changed: exit status 1" "$?" 1
ok "an F line changed: 1 differ" "$(grep -c '3 match, 1 differ' "$DIR/changed.out")" 1
ok "an F line changed: tic 3 named" "$(grep -c '^net-viewer: DIFFERS tic 3:' "$DIR/changed.out")" 1
"$RUBY" "$VIEWER" --replay "$DIR/flipped.rec" --console "$DIR/console.log" --max-loss 1 > "$DIR/flipped.out" 2>&1
ok "a screen byte flipped: exit status 1" "$?" 1
ok "a screen byte flipped: tic 1 named" "$(grep -c '^net-viewer: DIFFERS tic 1:' "$DIR/flipped.out")" 1
"$RUBY" "$VIEWER" --replay "$DIR/bad.rec" --console "$DIR/console.log" --max-loss 1 > "$DIR/bad.out" 2>&1
ok "boot id 0, version 1, an unknown kind: exit status 1" "$?" 1
ok "  each counted with its reason" "$(grep -c '3 bad (1 boot id 0, 1 version 1, 1 kind 0x51)' "$DIR/bad.out")" 1
"$RUBY" "$VIEWER" --replay "$DIR/v2.rec" > "$DIR/v2.out" 2>&1
ok "0024's version 2: exit status 1, every datagram bad, no boot" \
   "$?:$(grep -c '^net-viewer: 252 datagram(s), 252 bad (252 version 2); 0 boot(s)$' "$DIR/v2.out")" "1:1"
"$RUBY" "$VIEWER" --replay "$DIR/badinput.rec" > "$DIR/badinput.out" 2>&1
ok "input state 3, none with a session, held with session 0: exit status 1" "$?" 1
ok "  each counted with its reason" \
   "$(grep -c '3 bad (1 input state 3, 1 no input with a session or sequence, 1 input state 1 with session 0)' "$DIR/badinput.out")" 1
"$RUBY" "$VIEWER" --replay "$DIR/transport.rec" --console "$DIR/console.log" --max-loss 1 > "$DIR/transport.out" 2>&1
ok "a T, which 0024 abolished: exit status 1, bad as kind 0x54" \
   "$?:$(grep -c '1 bad (1 kind 0x54)' "$DIR/transport.out")" "1:1"
"$RUBY" "$VIEWER" --replay "$DIR/backwards.rec" > "$DIR/backwards.out" 2>&1
ok "a tic going backwards: exit status 1, tic 3 named" \
   "$?:$(grep -c '^net-viewer: FAIL boot 1234abcd: 1 piece(s) of a tic going backwards (first tic 3): two boots share this id$' "$DIR/backwards.out")" "1:1"
"$RUBY" "$VIEWER" --replay "$DIR/inconsistent.rec" --console "$DIR/console.log" --max-loss 1 > "$DIR/inconsistent.out" 2>&1
ok "an S that does not add up: exit status 1, named" \
   "$?:$(grep -c '^net-viewer: FAIL boot 1234abcd: 1 S message(s) whose sent, not sent and dropped do not add up' "$DIR/inconsistent.out")" "1:1"
for c in noB:'the console has no B line' twoBlines:'the console has 2 B lines' otherB:"the console's boot 77777777 sent no datagram here"; do
  n=${c%%:*}; want=${c#*:}
  "$RUBY" "$VIEWER" --replay "$DIR/drops.rec" --console "$DIR/$n.log" --max-loss 1 > "$DIR/$n.out" 2>&1
  ok "console $n: exit status 1, named" "$?:$(grep -c "^net-viewer: FAIL $want" "$DIR/$n.out")" "1:1"
done
"$RUBY" "$VIEWER" --replay "$DIR/empty.rec" --console "$DIR/console.log" --max-loss 6 > "$DIR/empty.out" 2>&1
ok "nothing received: exit status 1" "$?" 1
ok "nothing received: no frame matched, named" \
   "$(grep -c '^net-viewer: FAIL no frame matched its F line$' "$DIR/empty.out")" 1
ok "nothing received: 0 match" "$(grep -c '6 F line(s) (boot 1234abcd): 0 match, 0 differ' "$DIR/empty.out")" 1

echo "== showing"
"$RUBY" "$VIEWER" --replay "$DIR/one.rec" --ppm-dir "$DIR/ppm" --aspect 4:3 --scale 1 > "$DIR/ppm.out" 2>&1
ok "--ppm-dir: exit status 0" "$?" 0
ok "--ppm-dir: one frame shown" "$(grep -c '1 frame(s) shown' "$DIR/ppm.out")" 1
ok "4:3 at scale 1 is a 320x240 P6, its first pixel the palette's colour" \
   "$("$RUBY" -e '
      img = File.binread(ARGV[0]); pal = File.binread(ARGV[1]); s = File.binread(ARGV[2])
      head = "P6\n320 240\n255\n"
      print img.start_with?(head) && img.bytesize == head.bytesize + 320 * 240 * 3 &&
            img.byteslice(head.bytesize, 3) == pal.byteslice(3 * s.getbyte(0), 3) ? "yes" : "no"
    ' "$DIR/ppm/tic000000.ppm" "$DIR/palette.bin" "$DIR/screen0.bin")" yes

echo "== usage"
"$RUBY" "$VIEWER" --replay "$DIR/cut.rec" > "$DIR/cut.out" 2>&1
ok "a recording cut inside a datagram: exit status 2" "$?" 2

echo "net-viewer: $pass passed, $fail failed ($(( $(date +%s) - T0 )) s)"
[ "$fail" -eq 0 ]
