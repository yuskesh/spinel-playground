#!/bin/sh
#
# tests/doom-core/net-view.sh -- examples/doom/net_view, the SDL2 viewer of the
# board's frames, on planted datagrams.
#
#   LLVM_PREFIX=... | CC=... [RUBY=ruby] sh tests/doom-core/net-view.sh DIR
#
# Decision 0024's viewer compiled by Spinel, as examples/doom/net_view/
# build.sh builds it, with no board and no window: SDL runs on its dummy video
# driver, and the viewer's --bmp writes what it last presented. The datagrams
# are planted here in wire version 3 (decision 0025 point 15) and
# tools/doom/net_frames.rb's recording form. Boot 1234abcd sends a palette,
# three tics of a pattern that differs per tic (tic 1's pieces in reverse
# order) and an S. The viewer judges nothing; tools/doom/net-viewer.rb
# does, and here it reads the viewer's --record file.
#
# WHAT IT CHECKS
#   * the build, with the compiler the environment selects
#   * --replay: one boot, 3 complete frames shown, none not shown, nothing
#     bad; the boot's S reported; the BMP of the last frame is the
#     palette's colour of tic 2's screen, pixel for pixel; --record writes
#     back the recording it read, byte for byte
#   * live, over loopback UDP: the 152 datagrams received and recorded as
#     they were sent, byte for byte; 3 frames complete, each shown or counted
#     as not shown; net-viewer.rb --replay reads that recording: 3 complete
#   * two boots interleaved piece by piece, each with its own palette: never
#     combined; the newer one's 3 frames shown, the other's 3 not shown; the
#     BMP is the newer boot's last screen in the newer boot's palette
#   * a late viewer: a frame before the palette waits for it; a second,
#     different palette replaces the first (the BMP is in its colours)
#   * the keys (decision 0025), live over loopback against a planted board
#     that answers each K with a frame carrying it, with --keys, a key
#     script pressing fire for its tics 3 to 5 and --first-seq 4294967294:
#     no K before the boot is known; every K 17 bytes, kind 0x4B, version
#     1, the session the viewer printed and the boot shown; the sequence
#     numbers consecutive, wrapping past 4294967295 to 0; fire (bit 6) set
#     in a run of them and the reserved bits clear; the last K releases
#     every key; the viewer counts the sends the board received; latency
#     matched once per sequence number the frames carried, at receipt, and
#     at most that many at present
#   * the same against a board whose frames carry another session's input,
#     input released by the time-out, no input, or this session's but a
#     sequence never sent: nothing matched, the last counted as no longer
#     kept
#   * --keys PORT, with the board on 127.0.0.2: the destination printed
#     once, every K reaches the boot's source; a control, half of each
#     frame's pieces sent from 127.0.0.3, moves nothing (no K there); a new
#     boot from 127.0.0.3 moves the keys there, its destination printed.
#     Skipped, named, where 127.0.0.2 or 127.0.0.3 cannot be bound
#   * usage: --keys with --replay, --script without --keys, and a --keys
#     that is not [ADDR:]PORT, each exit 2
#   * failing controls:
#       a piece of tic 1 missing          -> 1 incomplete (1 piece), 2 shown
#       a piece with boot id 0, one of
#         version 1, one of an unknown kind -> 3 bad, the first named; no
#                                            boot's counts change
#       a piece of tic 3 after tic 20     -> 1 backwards, not used
#       a screen byte changed in tic 2    -> the BMP check finds that pixel
#                                            (piece 7's byte 88: 88,28)
#       a T (0x54), which 0024 abolished -> 1 bad, kind 0x54; the
#                                            boot's counts unchanged
#       the run in version 2, 0024's wire -> every datagram bad, no boot,
#                                            nothing shown
#       one piece of tic 1 with another
#         sequence                        -> tic 1 incomplete, mismatched,
#                                            no piece missing; 2 shown
#       a recording cut inside a datagram -> exit 2
#       an unknown option                 -> exit 2
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIR=${1:?usage: net-view.sh DIR}
RUBY=${RUBY:-ruby}
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
T0=$(date +%s)
mkdir -p "$DIR" || exit 2
VIEW=$DIR/net_view
SDL_VIDEODRIVER=dummy
export SDL_VIDEODRIVER

echo "== the build"
sh "$ROOT/examples/doom/net_view/build.sh" "$VIEW" > "$DIR/build.out" 2>&1
ok "build.sh: exit status 0" "$?" 0
[ -x "$VIEW" ] || { tail -5 "$DIR/build.out"; echo "net-view: FAIL no viewer built; see $DIR/build.out"; exit 1; }

# The screens, the palette and the recordings.
"$RUBY" -I"$ROOT/tools/doom" -rnet_frames -e '
  dir = ARGV[0]
  screens = (0..2).map { |t| Array.new(64_000) { |i| ((i % 320) * 7 + (i / 320) * 13 + t * 29) & 0xff }.pack("C*") }
  screens.each_with_index { |s, t| File.binwrite(File.join(dir, "screen#{t}.bin"), s) }
  palette = Array.new(768) { |i| (i * 37 + 11) & 0xff }.pack("C*")
  File.binwrite(File.join(dir, "palette.bin"), palette)
  other = palette.bytes.map { |c| c ^ 0x5a }.pack("C*")
  File.binwrite(File.join(dir, "other.bin"), other)
  a = 0x1234abcd
  b = 0x0badf00d
  hdr = ->(kind, boot, version = 3) { [kind, version, boot].pack("CCL<") }
  # the pieces of a frame, each with the input of the tic: session, sequence, state
  pieces = ->(boot, t, s, input = [0, 0, 0]) {
    (0...50).map { |k| hdr.(0x43, boot) + [t, k, 50, *input].pack("L<CCL<L<C") + s.byteslice(k * 1280, 1280) }
  }
  pal = ->(boot, rgb = palette) { hdr.(0x50, boot) + rgb }
  rec = ->(name, dgrams) { File.open(File.join(dir, name), "wb") { |io| dgrams.each { |d| NetFrames::Recording.write(io, d) } } }
  is_piece = ->(d, t, k) { d.getbyte(0) == 0x43 && d.unpack("@6L<C") == [t, k] }
  run = [pal.(a)] + pieces.(a, 0, screens[0]) + pieces.(a, 1, screens[1]).reverse + pieces.(a, 2, screens[2]) +
        [hdr.(0x53, a) + [2, 3, 0, 0, 0].pack("L<5")]
  rec.("run.rec", run)
  two = [pal.(a), pal.(b, other)]
  (0..2).each { |t| two += pieces.(a, t, screens[t]).zip(pieces.(b, t, screens[2 - t])).flatten }
  rec.("two.rec", two)
  rec.("lateview.rec", pieces.(a, 0, screens[0]) + [pal.(a)] + pieces.(a, 1, screens[1]) + [pal.(a, other)] + pieces.(a, 2, screens[2]))
  rec.("missing.rec", run.reject { |d| is_piece.(d, 1, 30) })
  rec.("bad.rec", run + [pieces.(0, 3, screens[0])[0], pieces.(a, 3, screens[0])[0].dup.tap { |d| d.setbyte(1, 1) },
                         hdr.(0x51, a) + "x" * 20])
  rec.("t.rec", run + [hdr.(0x54, a) + [152, 0, 1].pack("L<3")])
  rec.("v2.rec", run.map { |d| d.dup.tap { |x| x.setbyte(1, 2) } })
  rec.("mixed.rec", run.map { |d| is_piece.(d, 1, 30) ? pieces.(a, 1, screens[1], [0x5e55, 8, 1])[30] : d })
  rec.("backwards.rec", [pal.(a)] + pieces.(a, 20, screens[0]) + [pieces.(a, 3, screens[1])[0]])
  changed = run.map(&:dup)
  i = changed.index { |d| is_piece.(d, 2, 7) }
  changed[i].setbyte(NetFrames::PIECE_HEADER + 88, changed[i].getbyte(NetFrames::PIECE_HEADER + 88) ^ 0x55)
  rec.("changed.rec", changed)
  File.binwrite(File.join(dir, "cut.rec"), File.binread(File.join(dir, "run.rec"))[0, 2000])
' "$DIR" || exit 1

# bmp_check BMP SCREEN [PALETTE]: "match", or the first pixel that is not the
# palette's colour of the screen's byte (palette.bin unless given). SDL
# writes a 32-bit BMP, its rows bottom-up.
bmp_check() {
  "$RUBY" -e '
    b = File.binread(ARGV[0]); s = File.binread(ARGV[1]); pal = File.binread(ARGV[2])
    off, = b.unpack("@10L<"); w, h, _, bpp = b.unpack("@18l<l<S<S<")
    abort "not a 320x200 32-bit BMP (#{w}x#{h}x#{bpp})" unless w == 320 && h.abs == 200 && bpp == 32
    bad = nil
    200.times do |y|
      row = h > 0 ? 199 - y : y
      320.times do |x|
        bb, g, r = b.unpack("@#{off + (row * 320 + x) * 4}C3")
        c = s.getbyte(y * 320 + x)
        next if [r, g, bb] == [pal.getbyte(3 * c), pal.getbyte(3 * c + 1), pal.getbyte(3 * c + 2)]

        bad = "pixel #{x},#{y}"
        break
      end
      break if bad
    end
    print bad || "match"
  ' "$1" "$2" "${3:-$DIR/palette.bin}"
}
RUN_BOOT='boot 1234abcd, shown: datagrams 152, palettes 1, frames complete 3, incomplete 0 (0 pieces missing), late 0, duplicate 0, backwards 0$'

echo "== --replay"
"$VIEW" --replay "$DIR/run.rec" --bmp "$DIR/run.bmp" --record "$DIR/run-again.rec" > "$DIR/run.out" 2>&1
ok "exit status 0" "$?" 0
ok "one boot, 3 shown, nothing bad" "$(grep -c 'datagrams 152, bad 0, boots 1, shown 3, not shown 0$' "$DIR/run.out")" 1
ok "the boot's counts" "$(grep -c "$RUN_BOOT" "$DIR/run.out")" 1
ok "its S" "$(grep -c 'boot 1234abcd: S tic 2, sent 3, not sent 0, dropped 0, messages dropped 0$' "$DIR/run.out")" 1
ok "no T line" "$(grep -c ': T ' "$DIR/run.out")" 0
ok "the BMP is tic 2's screen through the palette" "$(bmp_check "$DIR/run.bmp" "$DIR/screen2.bin")" match
cmp -s "$DIR/run.rec" "$DIR/run-again.rec"
ok "--record writes back the recording read" "$?" 0

echo "== live, over loopback"
PORT=$((40000 + $$ % 20000))
rm -f "$DIR/live.rec"
"$VIEW" --bind 127.0.0.1 --port "$PORT" --record "$DIR/live.rec" --idle 2 > "$DIR/live.out" 2>&1 &
vpid=$!
n=0
until grep -q '^net_view: listening' "$DIR/live.out" 2>/dev/null || [ $n -ge 50 ]; do sleep 0.1; n=$((n + 1)); done
"$RUBY" -I"$ROOT/tools/doom" -rnet_frames -rsocket -e '
  u = UDPSocket.new
  NetFrames::Recording.each(File.binread(ARGV[0])) { |d| u.send(d, 0, "127.0.0.1", ARGV[1].to_i) }
' "$DIR/run.rec" "$PORT"
wait "$vpid"
ok "exit status 0" "$?" 0
ok "the boot's counts" "$(grep -c "$RUN_BOOT" "$DIR/live.out")" 1
ok "every complete frame shown or counted as not shown" \
   "$(sed -n 's/.*bad 0, boots 1, shown \([0-9]*\), not shown \([0-9]*\)$/\1 \2/p' "$DIR/live.out" | awk '{ print $1 + $2 }')" 3
cmp -s "$DIR/run.rec" "$DIR/live.rec"
ok "--record holds the datagrams as they were sent" "$?" 0
"$RUBY" "$ROOT/tools/doom/net-viewer.rb" --replay "$DIR/live.rec" > "$DIR/live-judge.out" 2>&1
ok "net-viewer.rb --replay reads the recording: 3 complete" \
   "$(grep -c 'boot 1234abcd: 152 datagram(s), palette received (1 time(s)); frames: 3 complete (0 before the palette), 0 incomplete (0 piece(s) missing), 0 absent; 0 late, 0 duplicate, 0 backwards' "$DIR/live-judge.out")" 1

echo "== boots and palettes"
"$VIEW" --replay "$DIR/two.rec" --bmp "$DIR/two.bmp" > "$DIR/two.out" 2>&1
ok "two boots: the newer shown, the other's frames not shown" \
   "$(grep -c 'datagrams 302, bad 0, boots 2, shown 3, not shown 3$' "$DIR/two.out")" 1
ok "two boots: never combined" \
   "$(grep -c 'boot 1234abcd: datagrams 151, palettes 1, frames complete 3,\|boot 0badf00d, shown: datagrams 151, palettes 1, frames complete 3,' "$DIR/two.out")" 2
ok "two boots: the BMP is the newer boot's last screen in its own palette" \
   "$(bmp_check "$DIR/two.bmp" "$DIR/screen0.bin" "$DIR/other.bin")" match
"$VIEW" --replay "$DIR/lateview.rec" --bmp "$DIR/lateview.bmp" > "$DIR/lateview.out" 2>&1
ok "a frame before the palette waits for it; all 3 shown" "$(grep -c 'boots 1, shown 3, not shown 0$' "$DIR/lateview.out")" 1
ok "a second palette replaces the first" "$(bmp_check "$DIR/lateview.bmp" "$DIR/screen2.bin" "$DIR/other.bin")" match

echo "== keys"
# A planted board: it binds the inbound port on each address of ADDRS (the
# first is the board, 127.0.0.1 unless given), takes the K messages, and
# answers each 28 ms with a frame carrying the latest K, as MODE says:
#   echo    its session and sequence, held, from the board, boot 1234abcd
#   other   in turn another session, released by the time-out, no input, and
#           this session with a sequence never sent
#   decoy   as echo, but every odd piece comes from the second address
#   reboot  as echo for 0.6 s, then boot 0badf00d from the second address
# It writes every K each address received as hex (k, then k1), how many came
# before its first datagram, the sequence numbers its frames carried held and
# how many frames carried a sequence never sent.
cat > "$DIR/board.rb" <<'EOF'
require "socket"
mode, vport, bport, out = ARGV[0], ARGV[1].to_i, ARGV[2].to_i, ARGV[3]
addrs = (ARGV[4] || "127.0.0.1").split(",")
socks = addrs.map { |a| UDPSocket.new.tap { |u| u.bind(a, bport) } }
ks = socks.map { [] }
last = nil
drain = lambda do
  socks.each_with_index do |u, i|
    loop { k = u.recv_nonblock(100); ks[i] << k; last = k }
  rescue IO::WaitReadable
    nil
  end
end
hdr = ->(k, boot) { [k, 3, boot].pack("CCL<") }
sleep 0.3
drain.()
before = ks.sum(&:size)
boot = 0x1234abcd
from = socks[0]
from.send(hdr.(0x50, boot) + "\x01".b * 768, 0, "127.0.0.1", vport)
echoed = {}
unsent = 0
tic = 0
t0 = Time.now
while Time.now - t0 < 1.2
  drain.()
  if mode == "reboot" && boot == 0x1234abcd && Time.now - t0 >= 0.6
    boot = 0x0badf00d
    from = socks[1]
    from.send(hdr.(0x50, boot) + "\x01".b * 768, 0, "127.0.0.1", vport)
    tic = 0
    last = nil
  end
  if last
    _, _, s, _, q = last.unpack("CCL<L<L<")
    input = if mode == "other" then [[s ^ 1, q, 1], [s, q, 2], [0, 0, 0], [s, (q + 5000) & 0xffffffff, 1]][tic % 4]
            else [s, q, 1]
            end
    echoed[[boot, q]] = true if mode != "other"
    unsent += 1 if mode == "other" && tic % 4 == 3
    50.times do |k|
      u = mode == "decoy" && k.odd? ? socks[1] : from
      u.send(hdr.(0x43, boot) + [tic, k, 50, *input].pack("L<CCL<L<C") + "\x02".b * 1280, 0, "127.0.0.1", vport)
    end
    tic += 1
  end
  sleep 0.028
end
sleep 1.5
drain.()
File.open(out, "w") do |io|
  io.puts "before #{before}"
  io.puts "echoed #{echoed.size}"
  io.puts "unsent #{unsent}"
  ks.each_with_index { |l, i| l.each { |k| io.puts "k#{i.zero? ? '' : i} #{k.unpack1("H*")}" } }
end
EOF
printf '3 5 fire\n' > "$DIR/fire.txt"
# keys_run MODE NAME [viewer options]: the viewer against the planted board,
# with --keys 127.0.0.1:BP, or --keys BP and the board on ADDRS when ADDRS is
# set
keys_run() {
  mode=$1; name=$2; shift 2
  VP=$((40000 + $$ % 20000 + 1)); BP=$((VP + 1))
  if [ -n "${ADDRS:-}" ]; then kto=$BP; else kto=127.0.0.1:$BP; fi
  "$VIEW" --bind 127.0.0.1 --port "$VP" --keys "$kto" --idle 1 "$@" > "$DIR/$name.out" 2>&1 &
  kpid=$!
  n=0
  until grep -q '^net_view: listening' "$DIR/$name.out" 2>/dev/null || [ $n -ge 50 ]; do sleep 0.1; n=$((n + 1)); done
  "$RUBY" "$DIR/board.rb" "$mode" "$VP" "$BP" "$DIR/$name.board" ${ADDRS:+"$ADDRS"}
  wait "$kpid"
}
keys_run echo keys --script "$DIR/fire.txt" --first-seq 4294967294
ok "exit status 0" "$?" 0
session=$(sed -n 's/^net_view: keys to .*, session \([0-9a-f]*\), first sequence 4294967294, from the key script .*/\1/p' "$DIR/keys.out")
ok "the session printed" "$(printf '%s' "$session" | wc -c | tr -d ' ')" 8
ok "no K before the boot is known" "$(grep -c '^before 0$' "$DIR/keys.board")" 1
"$RUBY" -e '
  ks = File.readlines(ARGV[0]).grep(/^k /).map { |l| [l.split[1]].pack("H*") }
  sess = ARGV[1].to_i(16)
  puts "count #{ks.size}"
  puts "shape #{ks.all? { |k| k.bytesize == 17 && k.unpack("CC") == [0x4b, 1] && k.unpack1("@2L<") == sess && k.unpack1("@6L<") == 0x1234abcd }}"
  q = ks.map { |k| k.unpack1("@10L<") }
  puts "first #{q.first}"
  puts "consecutive #{q.each_cons(2).all? { |x, y| y == (x + 1) & 0xffffffff }}"
  puts "wraps #{q.include?(4294967295) && q.include?(0)}"
  m = ks.map { |k| b0, b1, b2 = k.unpack("@14C3"); b0 | (b1 << 8) | (b2 << 16) }
  puts "fire run #{m.chunk_while { |x, y| x == y }.map(&:first).join(",")}"
  puts "reserved #{m.count { |x| (x >> 18) != 0 }}"
  puts "last #{m.last}"
' "$DIR/keys.board" "${session:-0}" > "$DIR/keys.k"
ok "every K: 17 bytes, K, version 1, the session printed, the boot shown" "$(grep -c '^shape true$' "$DIR/keys.k")" 1
ok "the sequence numbers start at --first-seq, consecutive" \
   "$(grep -c '^first 4294967294$' "$DIR/keys.k")$(grep -c '^consecutive true$' "$DIR/keys.k")" 11
ok "  and wrap past 4294967295 to 0" "$(grep -c '^wraps true$' "$DIR/keys.k")" 1
ok "fire (bit 6) in one run, between released keys" "$(grep -c '^fire run 0,64,0$' "$DIR/keys.k")" 1
ok "the reserved bits clear" "$(grep -c '^reserved 0$' "$DIR/keys.k")" 1
ok "the last K releases every key" "$(grep -c '^last 0$' "$DIR/keys.k")" 1
got=$(sed -n 's/^count //p' "$DIR/keys.k")
ok "the sends the viewer counts are the ones the board received, one at the end" \
   "$(grep -c "^net_view: keys session $session: sends $got (.* 1 at the end), failed 0, sequence 4294967294 to " "$DIR/keys.out")" 1
echoed=$(sed -n 's/^echoed //p' "$DIR/keys.board")
ok "latency at receipt: once per sequence number the frames carried" \
   "$(grep -c "^net_view: latency, key sample to frame received: $echoed matched, min [0-9]* us" "$DIR/keys.out")" 1
pr=$(sed -n 's/^net_view: latency, key sample to present called: \([0-9]*\) matched.*/\1/p' "$DIR/keys.out")
ok "latency at present: some, and at most that many" "$([ "${pr:-0}" -ge 1 ] && [ "${pr:-0}" -le "${echoed:-0}" ] && echo yes)" yes
ok "nothing no longer kept" "$(grep -c '^net_view: frames of this session with a sequence no longer kept: 0$' "$DIR/keys.out")" 1

keys_run other keys-other
ok "another session, released, none, never sent: exit status 0" "$?" 0
ok "  nothing matched at receipt or present" \
   "$(grep -c '^net_view: latency, key sample to .*: 0 matched$' "$DIR/keys-other.out")" 2
unsent=$(sed -n 's/^unsent //p' "$DIR/keys-other.board")
ok "  the sequence never sent counted as no longer kept" \
   "$(grep -c "^net_view: frames of this session with a sequence no longer kept: $unsent\$" "$DIR/keys-other.out")" 1
ok "  the input of the complete frames counted by state" \
   "$(grep -c '^net_view: boot 1234abcd: input of the complete frames: none [1-9][0-9]*, held [1-9][0-9]*, released [1-9][0-9]*; mismatched 0$' "$DIR/keys-other.out")" 1

# --keys PORT: the board on 127.0.0.2, a second address 127.0.0.3. Linux
# answers on all of 127/8; where 127.0.0.2 cannot be bound (macOS without an
# alias) these checks are skipped, named.
if "$RUBY" -rsocket -e 'UDPSocket.new.bind("127.0.0.2", 0); UDPSocket.new.bind("127.0.0.3", 0)' 2>/dev/null; then
  # kcount NAME TAG: how many K the address TAG names received; kboot: the boot
  # ids of those K, as hex of their bytes 6..9 on the wire
  kcount() { grep -c "^$2 " "$DIR/$1.board"; }
  kboot() { grep "^$2 " "$DIR/$1.board" | cut -d' ' -f2 | cut -c13-20 | sort -u | tr '\n' ' '; }
  ADDRS=127.0.0.2,127.0.0.3 keys_run decoy keys-auto
  ok "--keys PORT: exit status 0" "$?" 0
  ok "  the destination is the boot's source, printed once" \
     "$(grep -c "^net_view: keys to 127.0.0.2:$BP for boot 1234abcd\$" "$DIR/keys-auto.out"):$(grep -c '^net_view: keys to .* for boot' "$DIR/keys-auto.out")" "1:1"
  sends=$(sed -n 's/^net_view: keys session [0-9a-f]*: sends \([0-9]*\) .*/\1/p' "$DIR/keys-auto.out")
  ok "  every K reached the boot's source" "$(kcount keys-auto k)" "${sends:-none}"
  ok "  pieces of the same boot from another address do not move it: no K there" "$(kcount keys-auto k1)" 0
  ok "  the frames from both addresses were assembled" \
     "$(grep -c '^net_view: boot 1234abcd, shown: .*frames complete [1-9][0-9]*, incomplete 0 ' "$DIR/keys-auto.out")" 1
  ADDRS=127.0.0.2,127.0.0.3 keys_run reboot keys-reboot
  ok "a new boot from another address: exit status 0" "$?" 0
  ok "  each boot's destination printed" \
     "$(grep -c "^net_view: keys to 127.0.0.2:$BP for boot 1234abcd\$\|^net_view: keys to 127.0.0.3:$BP for boot 0badf00d\$" "$DIR/keys-reboot.out")" 2
  # the boot id is bytes 6..9 of K, little-endian: cdab3412 and 0df0ad0b in hex
  ok "  the first boot's K to the first address, the new boot's to the second" \
     "$(kboot keys-reboot k):$(kboot keys-reboot k1)" "cdab3412 :0df0ad0b "
else
  echo "  SKIP --keys PORT: 127.0.0.2 or 127.0.0.3 cannot be bound here (macOS loopback has only 127.0.0.1 unless aliased)"
fi

"$VIEW" --replay "$DIR/run.rec" --keys 127.0.0.1:5030 > "$DIR/usage-replay.out" 2>&1
ok "--keys with --replay: exit status 2" "$?" 2
"$VIEW" --replay "$DIR/run.rec" --script "$DIR/fire.txt" > "$DIR/usage-script.out" 2>&1
ok "--script without --keys: exit status 2" "$?" 2
"$VIEW" --keys 127.0.0.300:5030 > "$DIR/usage-keys.out" 2>&1
ok "--keys not ADDR:PORT: exit status 2" "$?" 2

echo "== failing controls"
"$VIEW" --replay "$DIR/missing.rec" > "$DIR/missing.out" 2>&1
ok "a piece missing: tic 1 incomplete, 2 shown" \
   "$(grep -c 'shown 2, not shown 0$' "$DIR/missing.out")$(grep -c 'frames complete 2, incomplete 1 (1 pieces missing)' "$DIR/missing.out")" 11
"$VIEW" --replay "$DIR/bad.rec" > "$DIR/bad.out" 2>&1
ok "boot id 0, version 1, an unknown kind: 3 bad, the first named" "$(grep -c 'bad 3 (first: boot id 0), boots 1,' "$DIR/bad.out")" 1
ok "the bad datagrams are no boot's" "$(grep -c "$RUN_BOOT" "$DIR/bad.out")" 1
"$VIEW" --replay "$DIR/t.rec" > "$DIR/t.out" 2>&1
ok "a T: 1 bad, kind 0x54" "$(grep -c 'bad 1 (first: kind 0x54), boots 1,' "$DIR/t.out")" 1
ok "a T: the boot's counts unchanged" "$(grep -c "$RUN_BOOT" "$DIR/t.out")" 1
"$VIEW" --replay "$DIR/v2.rec" > "$DIR/v2.out" 2>&1
ok "0024's version 2: every datagram bad, no boot, nothing shown" \
   "$(grep -c '^net_view: datagrams 152, bad 152 (first: version 2), boots 0, shown 0, not shown 0$' "$DIR/v2.out")" 1
"$VIEW" --replay "$DIR/mixed.rec" > "$DIR/mixed.out" 2>&1
ok "a piece disagreeing on the input: tic 1 incomplete, mismatched, 2 shown" \
   "$(grep -c 'shown 2, not shown 0$' "$DIR/mixed.out")$(grep -c 'frames complete 2, incomplete 1 (0 pieces missing)' "$DIR/mixed.out")$(grep -c 'mismatched 1$' "$DIR/mixed.out")" 111
"$VIEW" --replay "$DIR/backwards.rec" > "$DIR/backwards.out" 2>&1
ok "a tic going backwards: counted, not used" "$(grep -c 'frames complete 1, incomplete 0 (0 pieces missing), late 0, duplicate 0, backwards 1$' "$DIR/backwards.out")" 1
"$VIEW" --replay "$DIR/changed.rec" --bmp "$DIR/changed.bmp" > "$DIR/changed.out" 2>&1
ok "a screen byte changed: the BMP check finds it" "$(bmp_check "$DIR/changed.bmp" "$DIR/screen2.bin")" "pixel 88,28"
"$VIEW" --replay "$DIR/cut.rec" > "$DIR/cut.out" 2>&1
ok "a recording cut inside a datagram: exit status 2" "$?" 2
ok "a recording cut inside a datagram: named" "$(grep -c 'recording cut inside a datagram at byte' "$DIR/cut.out")" 1
"$VIEW" --frobnicate 1 > "$DIR/usage.out" 2>&1
ok "an unknown option: exit status 2" "$?" 2

echo "net-view: $pass passed, $fail failed ($(( $(date +%s) - T0 )) s)"
[ "$fail" -eq 0 ]
