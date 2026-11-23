# frozen_string_literal: true
#
# tests/doom-core/harness/rt1186-consoles.rb -- planted consoles for
# tools/doom/board-frames.rb, framed as the board's transport frames them
# (0014: 0xA5, channel, length, payload).
#
#   ruby rt1186-consoles.rb FRAMES.tsv DIR
#
# Writes DIR/<name>.log and prints one row per control:
# name <TAB> --from bytes <TAB> partial (0/1) <TAB> --tics (0: none) <TAB>
# --identity <TAB> the FAIL text expected, or `pass`. Every console is the
# first three tics of the recording, printed by a firmware whose build id is
# ID, with what each control plants; the `clean` row is the same console with
# nothing planted. --identity is ID unless the row is about another build.
want = File.readlines(ARGV[0]).reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.chomp.split("\t") }
dir = ARGV[1]

frame = ->(payload, channel: 0, length: nil) { [0xA5, channel, length || payload.bytesize].pack("C*") + payload.b }
fline = ->(t) { format("F %016x %s %s %016x\n", t, want[t][1], want[t][2], 40_000_000) }
ID = "0123456789abcdef"
OTHER = "fedcba9876543210"
banner = "*** Booting Zephyr OS build v4.4.2 ***\r\n".b
boot = banner + "SPC_SESSION_ID #{ID}\r\nSPC_RUNNING app\r\n".b
run = boot + (0..2).map { |t| frame.(fline.(t)) }.join.b
# what the write's reset leaves before the lane's own: a run whose console
# was opened late (no banner) and was cut inside a frame
before = "SPC_RUNNING app\r\n".b + frame.(fline.(0))[0, 20]
wrong = format("F %016x %s %s %016x\n", 0, "0" * 16, "0" * 16, 1)

rows = []
plant = lambda do |name, bytes, expect, from: 0, partial: 1, tics: 0, identity: ID|
  File.binwrite(File.join(dir, "#{name}.log"), bytes)
  rows << [name, from, partial, tics, identity, expect]
end
plant.("clean", run, "pass")
plant.("after-reset", before + run, "pass", from: before.bytesize)
plant.("earlier-boot-read", boot + frame.(wrong) + run, "booted again")
plant.("earlier-boot-skipped", boot + frame.(wrong) + run, "pass", from: (boot + frame.(wrong)).bytesize)
plant.("no-boot", before + run.byteslice(banner.bytesize..), "no `*** Booting Zephyr`", from: before.bytesize)
plant.("reboot", run + boot + frame.(fline.(0)), "booted again")
plant.("reboot-in-cut-frame", run + frame.(fline.(3))[0, 30] + boot, "booted again")
plant.("other-channel", run + frame.(fline.(3), channel: 1), "names channel 1")
plant.("length-zero", run + frame.("", length: 0), "outside the console's 1..136")
plant.("too-long", run + frame.("F #{'0' * 200}\n"), "outside the console's 1..136")
plant.("two-lines", run + frame.("D 0000000000000003\nD 0000000000000003\n"), "not one line")
plant.("not-a-loop-line", run + frame.("hello\n"), "not a loop line")
plant.("cut-at-end", run + frame.(fline.(3))[0, 30], "ends inside a frame", partial: 0)
plant.("fault", run + "E: ***** USAGE FAULT *****\r\nE:   Stack overflow (context area not valid)\r\n".b, "faulted")
plant.("refused", boot + "SPC_SESSION_REFUSED 3\r\n".b, "session was refused")
# the build: the firmware's id must be the build the lane wrote, printed once,
# before the first frame; a console of firmware written before is refused
no_id = banner + "SPC_RUNNING app\r\n".b + (0..2).map { |t| frame.(fline.(t)) }.join.b
plant.("no-identity", no_id, "printed no SPC_SESSION_ID")
plant.("other-build", run, "is build #{ID}, not the build written (#{OTHER})", identity: OTHER)
plant.("other-build-tics", run, "is build #{ID}, not the build written (#{OTHER})", partial: 0, tics: 3, identity: OTHER)
plant.("identity-twice", run.sub("SPC_RUNNING app".b, "SPC_SESSION_ID #{ID}\r\nSPC_RUNNING app".b), "SPC_SESSION_ID 2 times")
plant.("identity-after-frame", no_id + "SPC_SESSION_ID #{ID}\r\n".b, "comes after the first frame")
plant.("bad-identity-argument", run, "is not 16 hex digits", identity: "-")
# a line of the form before 2026-10-21, with the SHA-256, is not read
plant.("sha256-form", run + frame.(format("F %016x %s %s %s %016x\n", 3, want[3][1], want[3][2], "0" * 64, 1)), "not a loop line")
plant.("wrong-digest", run + frame.(wrong.sub("F 0000000000000000", format("F %016x", 3))), "tic 3:")
# decision 0024's frame channel: `B` once, after F lines of the same boot,
# and `N` before `D`, in its three-count and its first two-count form, are
# read; a second of either is refused
bline = frame.("B 000000001234abcd\n")
nline = frame.(format("N %016x %016x %016x\n", 1, 2, 3))
plant.("boot-and-drops", boot + frame.(fline.(0)) + bline + frame.(fline.(1)) + frame.(fline.(2)) + nline, "pass")
plant.("drops-two-counts", run + frame.(format("N %016x %016x\n", 1, 2)), "pass")
plant.("boot-twice", boot + frame.(fline.(0)) + bline + frame.(fline.(1)) + bline + frame.(fline.(2)), "2 B lines")
plant.("drops-twice", run + nline + nline, "2 N lines")
# --tics N: the first N frames, the run not waited for, the end may be cut
cut = run + frame.(fline.(3))[0, 30]
plant.("tics-cut", cut, "pass", partial: 0, tics: 3)
plant.("tics-short", cut, "fewer than the first 4 asked for", partial: 0, tics: 4)
plant.("tics-wrong", boot + frame.(fline.(0)) + frame.(wrong.sub("F 0000000000000000", format("F %016x", 1))) + frame.(fline.(2)), "tic 1:", partial: 0, tics: 2)
plant.("tics-stopped", boot + frame.(fline.(0)) + frame.(format("X %016x step %016x\n", 1, 7)), "the run stopped before tic 2", partial: 0, tics: 2)
plant.("tics-ended", boot + frame.(fline.(0)) + frame.(format("D %016x\n", 1)), "the run ended after 1 tics, before tic 2", partial: 0, tics: 2)
rows.each { |r| puts r.join("\t") }
