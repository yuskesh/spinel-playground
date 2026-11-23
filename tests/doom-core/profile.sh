#!/bin/sh
#
# tests/doom-core/profile.sh -- the stage-timing variant of the board loop,
# checked without a board.
#
#   SESSION_IMAGE=DIR [WAD=...] [RUBY=ruby] sh tests/doom-core/profile.sh DIR
#
# SESSION_IMAGE is a demo's session image for DEMO1
# (tools/doom/session-image.rb --demo DEMO1). It checks
#
#   1. examples/doom/core/board/profile.rb on the host (CoreApp::SessionHost,
#      as tests/app/session.sh runs app.rb), for 30 tics: every frame is the
#      recorded one, and a T line follows tics 0, 10 and 20 with its ten
#      fields. The host's clock answers 0, so the fields' values are checked
#      in 2;
#   2. tools/doom/board-profile.rb on a console framed as the board frames
#      it: those frames, with T lines planted with known cycle counts. The
#      stages come out in ms at 240 MHz, with the sum and total less the
#      sum;
#   3. its refusals, each by its message: a frame that is not the recorded
#      one (and then no stage table is written), a T line out of sequence,
#      a malformed T line, and a console whose SPC_SESSION_ID is not the
#      build's (--identity).
#
# The firmware build and the run on the board are not here: the variant is
# built with spinel-core-app as app.rb is, and run by hand (docs/building.md).
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DIR=${1:?usage: profile.sh DIR}
RUBY=${RUBY:-ruby}
FIX=$ROOT/tests/doom-core/fixtures/screens/DEMO1.tsv
pass=0; fail=0
ID=0123456789abcdef  # the build id the planted consoles print
ok() { if [ "$2" = "$3" ]; then echo "  pass $1"; pass=$((pass + 1))
       else echo "  FAIL $1 (got '$2', want '$3')"; fail=$((fail + 1)); fi; }
[ -n "${SESSION_IMAGE:-}" ] && [ -f "$SESSION_IMAGE/image.tsv" ] ||
  { echo "profile: SESSION_IMAGE must name DEMO1's session image" >&2; exit 2; }
mkdir -p "$DIR" || exit 2
s0=$(date +%s)

echo "profile: 1. profile.rb on the host, over DEMO1's session"
ROOT=$ROOT "$RUBY" -I"$ROOT/tools/app/lib" -I"$ROOT/examples/doom/lib" -e '
  require "core_app/session_host"
  # profile.rb takes the digests through its own Frame.fnv: the two FNV-1a 64
  # digests app.rb writes with Frame.digests
  Object.const_set(:Frame, Module.new)
  Frame.define_singleton_method(:fnv) do |screen, view, out|
    b = screen.pack("C*")
    "#{$host.fnv(b.byteslice(0, view))} #{$host.fnv(b)}".bytes.each_with_index { |x, i| out[i] = x }
    nil
  end
  $host = CoreApp::SessionHost.new(app_path: ARGV[1], image_dir: ARGV[0], root: ENV.fetch("ROOT"))
  File.binwrite(ARGV[2], $host.run(frames: 30).lines.join)' \
  "$SESSION_IMAGE" "$ROOT/examples/doom/core/board/profile.rb" "$DIR/host.txt" 2> "$DIR/host.err"
ok "the host run of 30 tics" "$?" 0
ok "every frame is the recorded one" \
   "$("$RUBY" -e 'g = File.read(ARGV[0]).lines.grep(/^F /).map { |l| l.split(" ")[2, 2] }
     w = File.readlines(ARGV[1]).reject { |l| l.start_with?("#") || l.strip.empty? }.first(30).map { |l| l.chomp.split("\t")[1, 2] }
     puts "#{g.size}|#{g == w}"' "$DIR/host.txt" "$FIX")" "30|true"
ok "a T line after tics 0, 10 and 20, each with ten fields" \
   "$("$RUBY" -e 't = File.read(ARGV[0]).lines.grep(/^T /).map(&:split)
     puts "#{t.map { |f| f[1].to_i(16) }.join(",")}|#{t.map(&:size).uniq.join(",")}"' "$DIR/host.txt")" "0,10,20|12"

echo "profile: 2. board-profile.rb on a framed console"
# the host's lines, framed, with T lines whose cycles are known: tic k's
# input is (k+1) ms, step 100 ms, cells 1, render 50, fnv 2, total 154 ms
# plus 1000 cycles, format 1000 cycles, put 2400 cycles, wall 200 ms,
# and k stalls
plant() { # console-out mode
  "$RUBY" -e '
    ms = 240_000
    out, mode = ARGV[1], ARGV[2]
    lines = File.read(ARGV[0]).lines.reject { |l| l.start_with?("T ") }
    body = +"*** Booting Zephyr OS build v4.4.2 ***\r\nSPC_SESSION_ID #{ARGV[3]}\r\nSPC_RUNNING app\r\n".b
    lines.each do |l|
      l = l.sub(/^F 0000000000000005 \h{16}/, "F 0000000000000005 #{"0" * 16}") if mode == "wrong-frame"
      body << [0xA5, 0, l.bytesize].pack("C*") << l.b
      t = l[/^F (\h{16})/, 1]&.to_i(16)
      next unless t && (t % 10).zero?
      k = mode == "out-of-sequence" && t == 10 ? 20 : t
      v = [(k + 1) * ms, 100 * ms, ms, 50 * ms, 2 * ms, 154 * ms + 1000 + k * ms, 1000, 2400, 200 * ms, k]
      tl = "T #{format("%016x", k)} " + v.map { |x| format("%08x", x) }.join(" ") + "\n"
      tl = tl.sub(/ \h{8}\n\z/, " zz\n") if mode == "malformed" && t == 20
      body << [0xA5, 0, tl.bytesize].pack("C*") << tl.b
    end
    File.binwrite(out, body)' "$DIR/host.txt" "$1" "$2" "$ID"
}
plant "$DIR/clean.log" clean
"$RUBY" "$ROOT/tools/doom/board-profile.rb" --console "$DIR/clean.log" --frames "$FIX" --identity "$ID" --out "$DIR/clean" --partial \
  > "$DIR/clean.out" 2>&1
ok "board-profile.rb reads the framed console" "$?" 0
ok "three sampled tics, in the table" "$(($(wc -l < "$DIR/clean/stages.tsv") - 1))" 3
ok "tic 10's row: input 11 ms, fnv 2, sum 164, gap 1000 cycles, format, put and wall in ms, 10 stalls" \
   "$(awk -F '\t' '$1 == 10 { print $2, $6, $7, $8, $9, $10, $11, $12, $13 }' "$DIR/clean/stages.tsv")" \
   "11.000 2.000 164.000 164.004 0.004 0.004 0.010 200.000 10"
ok "the summary's input row: three samples, min 1, median 11, p90 21, max 21 ms" \
   "$(grep '^input ' "$DIR/clean/summary.txt" | tr -s ' ')" \
   "input n 3 min 1.000 median 11.000 p90 21.000 max 21.000 ms"
ok "put and wall leave out tic 0, which has no previous tic" \
   "$(grep -E '^(put|wall) ' "$DIR/clean/summary.txt" | awk '{ print $3 }' | tr '\n' ' ')" "2 2 "

echo "profile: 3. refused, each by its message"
for c in "wrong-frame:no stage time is reported" "out-of-sequence:T line 1 is tic 20, not 10" "malformed:not a T line"; do
  m=${c%%:*}; want=${c#*:}
  plant "$DIR/$m.log" "$m"
  out=$("$RUBY" "$ROOT/tools/doom/board-profile.rb" --console "$DIR/$m.log" --frames "$FIX" --identity "$ID" --out "$DIR/$m" --partial 2>&1); rc=$?
  ok "$m" "$rc|$(printf '%s' "$out" | grep -cF "$want")" "1|1"
done
out=$("$RUBY" "$ROOT/tools/doom/board-profile.rb" --console "$DIR/clean.log" --frames "$FIX" --identity fedcba9876543210 \
  --out "$DIR/other-build" --partial 2>&1); rc=$?
ok "another build's console" "$rc|$(printf '%s' "$out" | grep -cF 'is build 0123456789abcdef, not the build written (fedcba9876543210)')" "1|1"
ok "a wrong frame writes no stage table" "$([ -f "$DIR/wrong-frame/stages.tsv" ] && echo written || echo none)" none

echo "profile: $((pass + fail)) checked, $pass pass, $fail fail; $(( $(date +%s) - s0 )) s"
[ "$fail" = 0 ]
