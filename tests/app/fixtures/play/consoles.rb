# frozen_string_literal: true
#
# tests/app/fixtures/play/consoles.rb -- planted consoles of play.rb for
# tools/doom/board-frames.rb --play, framed as the board's transport frames
# them (0014: 0xA5, channel, length, payload).
#
#   ruby consoles.rb DIR
#
# Writes DIR/<name>.log and prints one row per console: name <TAB> --tics
# <TAB> --expect-bad (- for none, LO-HI for --expect-bad LO --expect-bad-max
# HI) <TAB> the FAIL text expected, or `pass`.
# Each is five tics of a firmware whose build id is ID, with two I lines;
# `clean` plants nothing, and every other row one defect.
dir = ARGV[0]
ID = "0123456789abcdef"
frame = ->(payload) { [0xA5, 0, payload.bytesize].pack("C*") + payload.b }
fline = ->(t) { format("F %016x %016x %016x %016x\n", t, 0x1111 * (t + 1), 0x2222 * (t + 1), 25_000_000) }
iline = ->(c) { "I #{c.map { |x| format('%016x', x) }.join(' ')}\n" }
boot = "*** Booting Zephyr OS build v4.4.2 ***\r\nSPC_SESSION_ID #{ID}\r\nSPC_RUNNING app\r\n".b
I0 = [0, 0, 0, 0, 0, 0, 0].freeze
I1 = [9, 2, 1, 2, 4, 3, 1].freeze # 9 = 2 + 1 + 2 + 4
run = lambda do |lines|
  boot + lines.map { |l| frame.(l) }.join.b
end
clean = ["B 0000000000000001\n", fline.(0), iline.(I0), fline.(1), fline.(2), fline.(3), iline.(I1), fline.(4)]
rows = []
plant = lambda do |name, lines, expect, tics: 5, bad: "-"|
  File.binwrite(File.join(dir, "#{name}.log"), run.(lines))
  rows << [name, tics, bad, expect]
end
plant.("clean", clean, "pass")
plant.("expected-bad", clean, "pass", bad: 2)
plant.("other-bad", clean, "counts 2 bad, not the 3 expected", bad: 3)
# the range of planted and late (the coordinator, 2026-10-23): the clean console counts 2
plant.("bad-in-range", clean, "pass", bad: "1-3")
plant.("bad-at-low-end", clean, "pass", bad: "2-3")
plant.("bad-at-high-end", clean, "pass", bad: "1-2")
plant.("bad-below-range", clean, "counts 2 bad, below the 3 planted", bad: "3-4")
plant.("bad-above-range", clean, "counts 2 bad, above the 1 the planted and the late can make", bad: "0-1")
plant.("unbalanced", clean.map { |l| l == iline.(I1) ? iline.([10, 2, 1, 2, 4, 3, 1]) : l }, "is not bad + stale + superseded + applied")
plant.("count-down", clean + [iline.([9, 2, 1, 2, 4, 2, 1])], "a count went down")
plant.("no-i-line", clean.reject { |l| l.start_with?("I ") }, "wrote no I line")
plant.("d-line", clean + ["D 0000000000000005\n"], "it has no end")
plant.("stopped", clean.first(4) + ["X 0000000000000002 reborn 0000000000000000\n"], "stopped before tic 5")
plant.("order", clean.map { |l| l == fline.(2) ? fline.(3) : l }, "not tics 0, 1, 2")
plant.("too-many-applied", clean.map { |l| l == iline.(I1) ? iline.([9, 2, 1, 2, 4, 9, 1]) : l }, "more than the run's")
rows.each { |r| puts r.join("\t") }
