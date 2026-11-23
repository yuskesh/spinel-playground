# tests/app/fixtures/play/host.rb -- examples/doom/core/board/play.rb on the host
# (CoreApp::SessionHost), one scenario per call, for tests/app/play.sh.
#
#   ruby -I tools/app/lib tests/app/fixtures/play/host.rb IMAGE APP SCENARIO
#
# The clock moves P = ceil(1,000,000 / 35) cycles a release, so every release
# runs one tic (play.rb's pace) and a message given for release r is taken at
# tic r. The boot id is SessionHost's, 1; a message is valid for it from tic
# 1, once the stream has seen the id at tic 0. It prints one line,
#
#   counts=<dequeued>,<bad>,<stale>,<superseded>,<applied>,<tics applied>,<time-outs>
#   meta=<session>:<sequence>:<state> per tic, space-separated
#   cmds=<forward>,<side>,<angleturn>,<buttons>,<byte> per tic, space-separated
#
# and, for the stops, the X line and the calls. Nothing here judges; the
# suite compares with the values written there by hand.
require "core_app/session_host"

image, app, scenario = ARGV
P = (1_000_000 + 34) / 35
A = 0x0A0A0A0A
B = 0x0B0B0B0B
# the bits of decision 0025 point 5
BIT = { "right" => 0, "left" => 1, "up" => 2, "down" => 3, "comma" => 4, "period" => 5, "fire" => 6, "use" => 7,
        "strafe" => 8, "speed" => 9, "1" => 10, "2" => 11, "3" => 12, "4" => 13, "5" => 14, "6" => 15, "7" => 16, "8" => 17 }.freeze

def k(session, seq, keys = [], boot: [1, 0, 0, 0], kind: 0x4B, version: 1, extra: 0, len: 17)
  mask = keys.sum { |n| 1 << BIT.fetch(n) } | extra
  m = [kind, version].pack("CC") + [session].pack("L<") + boot.pack("C4") + [seq & 0xffff_ffff].pack("L<") +
      [mask & 0xff, (mask >> 8) & 0xff, (mask >> 16) & 0xff].pack("C3")
  m.byteslice(0, len).ljust(len, "\0")
end

def run(image, app, frames, inbound, planted: {})
  CoreApp::SessionHost.new(app_path: app, image_dir: image, root: ENV.fetch("ROOT"))
                      .run(frames: frames, inbound: inbound, cycles_per_release: P, planted: planted)
end

def report(r)
  inp = r.states.fetch("inp")
  metas = r.datagrams.select { |d| d.getbyte(0) == 0x43 && d.getbyte(10).zero? }.map do |d|
    s, q = d.byteslice(12, 8).unpack("L<L<")
    "#{s.zero? ? 0 : (s == A ? 'A' : (s == B ? 'B' : s))}:#{q}:#{d.getbyte(20)}"
  end
  cmds = r.commands.map { |c| c.join(",") }
  puts "counts=#{inp[6, 7].join(',')} meta=#{metas.join(' ')} cmds=#{cmds.join(' ')} full=#{r.inbound_full}"
end

case scenario
when "none"
  report(run(image, app, 5, []))
when "bad"
  report(run(image, app, 3, [[1, k(A, 1, len: 16)], [1, k(A, 1, kind: 0x6B)], [1, k(A, 1, version: 2)], [1, k(0, 1)],
                             [1, k(A, 1, extra: 1 << 18)], [1, k(A, 1, boot: [2, 0, 0, 0])]]))
when "intic"
  report(run(image, app, 5, [[1, k(A, 10)], [2, k(A, 12)], [2, k(A, 11)], [3, k(A, 13)], [3, k(A, 13)],
                             [4, k(A, 14)], [4, k(A, 15)]]))
when "wrap"
  report(run(image, app, 4, [[1, k(A, 0xffff_ffff)], [2, k(A, 0)], [3, k(A, 0x8000_0000)]]))
when "timeout"
  report(run(image, app, 24, [[1, k(A, 5, ["up"])], [21, k(A, 5, ["up"])], [22, k(A, 6, ["up"])], [23, k(B, 1)]]))
when "takeover"
  report(run(image, app, 23, [[1, k(A, 5, ["up"])], [20, k(B, 3, ["down"])], [21, k(A, 6, ["up"])], [22, k(B, 4, ["down"])]]))
when "sametic"
  report(run(image, app, 2, [[1, k(A, 5)], [1, k(B, 7)]]))
when "full"
  report(run(image, app, 2, (1..20).map { |q| [1, k(A, q)] }))
when "commands"
  # the cases of tests/app/fixtures/play/commands.tsv, one message a tic from tic 1
  rows = File.readlines(File.join(__dir__, "commands.tsv")).reject { |l| l.start_with?("#") || l.strip.empty? }
  inbound = rows.each_with_index.map { |l, i| [i + 1, k(A, i + 1, l.split("\t")[0].split("+").reject { |x| x == "none" })] }
  report(run(image, app, rows.size + 1, inbound))
when "stop"
  # the image is planted by the suite; at most three tics
  r = run(image, app, 3, [], planted: ENV["PLAY_PLANT"] ? { ENV["PLAY_PLANT"] => 4 } : {})
  x = r.lines.find { |l| l.start_with?("X ") }
  puts "x=#{x ? x.chomp : 'none'} frames=#{r.lines.count { |l| l.start_with?('F ') }} input=#{r.calls['input']} step=#{r.calls['step']} render=#{r.calls['render']}"
else
  abort "host.rb: unknown scenario #{scenario}"
end
