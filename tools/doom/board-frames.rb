# frozen_string_literal: true
#
# tools/doom/board-frames.rb — the board loop's console, against the recorded frames.
#
#   ruby tools/doom/board-frames.rb --console LOG --frames DEMOn.tsv --identity ID
#        [--from BYTES] [--channel N] [--size N] [--hz N] [--partial | --tics N] [--pair PAIR,COMPANION]
#   ruby tools/doom/board-frames.rb --play --console LOG --identity ID --tics N
#        [--from BYTES] [--hz N] [--expect-bad N [--expect-bad-max M]] [--expect-timeouts N]
#
# Decision 0021's acceptance, read off what examples/doom/core/board/app.rb
# writes: a line `F <tic> <view fnv> <full fnv> <cycles>` per frame
# (numbers in hexadecimal; the board computes no SHA-256 since the owner's
# decision of 2026-10-21 in 0021, and a line of the earlier form is refused), `D <tics>` when the demo ends, `X <tic> <what>
# <value>` when it stops. With the frame channel of decision 0024 it also
# writes `B <boot id>` once, at the first tic the M33 has published the id
# (`F` lines before it are the same boot), and `N <frames dropped> <messages
# dropped> [<frames not sent>]` before `D`; both are read and summarised, not
# judged here (tools/doom/net-viewer.rb judges the stream), and a second of
# either fails, since one console is one boot. --frames is the recording
# (tests/doom-core/fixtures/screens/DEMOn.tsv).
#
# THE CONSOLE IS DECODED AS 0014 FRAMES IT. The app writes each line on its
# `console` channel, and the transport puts it on the UART as a frame: 0xA5,
# the channel index (u8), the length (u8, 1..size), the payload
# (tools/app/templates/transport_uart.c.erb; tools/app/lib/core_app/console.rb
# reads it). Zephyr's own printk text (the boot banner, SPC_RUNNING, a fault)
# is unframed, between frames. Each frame here must name --channel (0, the
# console, the app's only channel) with a length within --size (136, the
# channel's), and hold exactly one loop line ending in a newline; anything
# else is a broken frame and fails, naming it.
#
# WHERE THE RUN STARTS. --from is the console's length in bytes just before
# the lane's own reset (rt_console writes it): what came before is the run the
# write's reset started, and is not read. The run starts at the first
# `*** Booting Zephyr` after --from (bytes between the two are that earlier
# run's, cut by the reset), and the decoding starts there, in step with the
# frames. A second banner anywhere after that start is a second boot and
# fails, whatever --partial says; the banner is searched in the raw bytes, so
# a frame the reboot cut cannot hide it. No banner after --from fails too.
#
# THE FIRMWARE MUST BE THE BUILD THE LANE WROTE. The firmware prints
# `SPC_SESSION_ID <id>` at boot, once its session image is accepted
# (tools/app/lib/core_app/session_steps.rb's session_id, recorded in
# build.json). --identity is that build's id: the run must print exactly one
# such line, with that id, before its first frame, or nothing is judged. A
# console from firmware written before, or from another build, fails here.
# With --pair (decision 0027) the run must also print SPC_PAIR_ID and
# SPC_COMPANION_ID once each, before its first frame, with those ids, and no
# SPC_PAIR_REFUSED, SPC_CHANNEL_REFUSED or SPC_M7_FATAL: in stage 2 the M33
# prints the M7's lines (the M7's refusal and fatal error from its header
# line) on the console it owns.
#
# It then checks that
#
#   * the frames are tics 0, 1, 2, ... in order, none missing or repeated;
#   * each frame's view and full digests are the recorded ones for its tic;
#   * the run ended with `D` naming as many tics as the recording holds, and
#     wrote no `X` (--partial: a run that stopped early is admitted, its
#     frames still checked, and the summary says how far it got; --tics N:
#     the first N frames must be there and be the recorded ones, and
#     nothing after them is read, so the run need not end and the console
#     may be cut inside a frame);
#
# and exits 1 naming the first frame that differs, or what is missing.
#
# --play reads examples/doom/core/board/play.rb's console (decision 0025)
# instead: there is no recording and no end, so the first N frames (--tics,
# required) must be tics 0, 1, 2, ... in order and nothing may stop the
# run before them; and every `I <dequeued> <bad> <stale> <superseded>
# <applied> <tics applied> <time-outs>` line must balance, dequeued = bad +
# stale + superseded + applied, each count at least the last line's, with no
# more tics applied than frames. --expect-bad and --expect-timeouts name what
# the last I line must hold (a sender's planted bad messages and gaps); with
# --expect-bad-max M the bad count may be anything from --expect-bad to M,
# the planted ones plus the sender's late messages to the boot before (a
# race 0025's rules count as bad, the coordinator 2026-10-23). A
# Zephyr fault or SPC_SESSION_REFUSED in the run's text fails first, naming
# it. The tic's cycles are summarised as information, not as a bound (--hz
# converts them to milliseconds).
require "optparse"
require_relative "../app/lib/core_app/console"

opt = { hz: nil, from: 0, channel: 0, size: 136 }
OptionParser.new do |o|
  o.on("--console LOG") { |v| opt[:console] = v }
  o.on("--frames TSV") { |v| opt[:frames] = v }
  o.on("--identity ID") { |v| opt[:identity] = v }
  o.on("--from BYTES", Integer) { |v| opt[:from] = v }
  o.on("--channel N", Integer) { |v| opt[:channel] = v }
  o.on("--size N", Integer) { |v| opt[:size] = v }
  o.on("--hz N", Integer) { |v| opt[:hz] = v }
  o.on("--partial") { opt[:partial] = true }
  o.on("--tics N", Integer) { |v| opt[:tics] = v }
  o.on("--play") { opt[:play] = true }
  o.on("--expect-bad N", Integer) { |v| opt[:expect_bad] = v }
  o.on("--expect-bad-max M", Integer) { |v| opt[:expect_bad_max] = v }
  o.on("--expect-timeouts N", Integer) { |v| opt[:expect_timeouts] = v }
  o.on("--pair PAIR,COMPANION") { |v| opt[:pair] = v.split(",", 2) }
end.parse!
(opt[:play] ? %i[console identity tics] : %i[console frames identity]).each { |k| opt[k] or abort("board-frames: --#{k} is required#{opt[:play] ? ' with --play' : ''}") }

want = opt[:play] ? [] : File.readlines(opt[:frames]).reject { |l| l.start_with?("#") || l.strip.empty? }.map { |l| l.chomp.split("\t") }
fail_with = ->(msg) { puts "board-frames: FAIL #{msg}"; exit 1 }
fail_with.("--identity #{opt[:identity].inspect} is not 16 hex digits") unless opt[:identity].match?(/\A\h{16}\z/)
raw = File.binread(opt[:console])
fail_with.("--from #{opt[:from]} is past the console's #{raw.bytesize} bytes") if opt[:from] > raw.bytesize
banner = "*** Booting Zephyr".b
start = raw.index(banner, opt[:from]) or fail_with.("no `*** Booting Zephyr` after byte #{opt[:from]}, the lane's reset")
again = raw.index(banner, start + banner.bytesize)
fail_with.("the board booted again at byte #{again}, after the run that started at byte #{start}") if again
parsed = CoreApp::Console.parse(raw.byteslice(start..))
lines = parsed.lines.map { |l| l.delete("\0") }
if (at = lines.index { |l| l.match?(/FAULT \*{5}|>>> ZEPHYR FATAL ERROR/) })
  fault = lines[at..].grep(/FAULT|FATAL|Stack|PC|pc:|Faulting|Current thread|xpsr|r0\/a1/i).first(8)
  fail_with.("the board faulted: #{fault.join(' | ')}")
end
refused = lines.find { |l| l.start_with?("SPC_SESSION_REFUSED") }
fail_with.("the session was refused: #{refused}") if refused
ids = lines.filter_map { |l| l[/\ASPC_SESSION_ID (\S*)\z/, 1] }
fail_with.("the run printed no SPC_SESSION_ID: the firmware is not known to be the build written (#{opt[:identity]})") if ids.empty?
fail_with.("the run printed SPC_SESSION_ID #{ids.size} times") if ids.size > 1
fail_with.("the firmware that ran is build #{ids[0]}, not the build written (#{opt[:identity]})") unless ids[0] == opt[:identity]
first_frame = raw.index("\xA5".b, start)
fail_with.("SPC_SESSION_ID comes after the first frame") if first_frame && raw.index("SPC_SESSION_ID".b, start) > first_frame
if opt[:pair]
  # decision 0027: the M7 prints the pair words the M33 companion wrote, once,
  # before its first frame, and they are the pair's build.json records
  pair, companion = opt[:pair]
  fail_with.("--pair #{opt[:pair].join(',').inspect} is not two ids of 16 hex digits") unless [pair, companion].all? { |x| x.to_s.match?(/\A\h{16}\z/) }
  bad = lines.find { |l| l.start_with?("SPC_PAIR_REFUSED", "SPC_CHANNEL_REFUSED") }
  fail_with.("the M7 refused the pair: #{bad}") if bad
  fatal = lines.find { |l| l.start_with?("SPC_M7_FATAL") }
  fail_with.("the M7 stopped on a fatal error: #{fatal}") if fatal
  { "SPC_PAIR_ID" => pair, "SPC_COMPANION_ID" => companion }.each do |key, want_id|
    got = lines.filter_map { |l| l[/\A#{key} (\S*)\z/, 1] }
    fail_with.("the run printed #{key} #{got.size} times, not once") unless got.size == 1
    fail_with.("#{key} is #{got[0]}, not the pair's #{want_id}") unless got[0] == want_id
    fail_with.("#{key} comes after the first frame") if first_frame && raw.index(key.b, start) > first_frame
  end
end
fail_with.("the console ends inside a frame") if parsed.truncated && !opt[:partial] && !opt[:tics]
fail_with.("the run wrote trace frames (channel 0xFE); this is no verification build") unless parsed.trace.empty?
frames = []
done = nil
stopped = nil
boots = []
drops = []
ilines = []
parsed.frames.each_with_index do |(ch, bytes), k|
  text = bytes.pack("C*")
  fail_with.("frame #{k} names channel #{ch}, not the console's #{opt[:channel]}") unless ch == opt[:channel]
  fail_with.("frame #{k} is #{bytes.size} bytes, outside the console's 1..#{opt[:size]}") unless bytes.size.between?(1, opt[:size])
  fail_with.("frame #{k} is not one line ending in a newline: #{text.inspect}") unless text.end_with?("\n") && text.count("\n") == 1
  l = text.chomp
  if (m = l.match(/\AF ([0-9a-f]{16}) ([0-9a-f]{16}) ([0-9a-f]{16}) ([0-9a-f]{16})\z/))
    frames << { tic: m[1].to_i(16), view: m[2], full: m[3], cycles: m[4].to_i(16) }
  elsif (m = l.match(/\AB ([0-9a-f]{16})\z/))
    boots << m[1]
  elsif (m = l.match(/\AN ([0-9a-f]{16}) ([0-9a-f]{16})(?: ([0-9a-f]{16}))?\z/))
    drops << m.captures.compact.map { |x| x.to_i(16) }
  elsif opt[:play] && (m = l.match(/\AI ((?:[0-9a-f]{16} ){6}[0-9a-f]{16})\z/))
    ilines << m[1].split.map { |x| x.to_i(16) }
  elsif (m = l.match(/\AD ([0-9a-f]{16})\z/))
    done = m[1].to_i(16)
  elsif (m = l.match(/\AX ([0-9a-f]{16}) (\S+) ([0-9a-f]{16})\z/))
    stopped = "tic #{m[1].to_i(16)}: #{m[2]} #{m[3].to_i(16)}"
  else
    fail_with.("frame #{k} is not a loop line: #{l.inspect}")
  end
end
fail_with.("the run wrote #{boots.size} B lines; one console is one boot") if boots.size > 1
fail_with.("the run wrote #{drops.size} N lines") if drops.size > 1
if (n = opt[:tics])
  # the first N tics only: the lane stopped reading after them on purpose
  fail_with.("the run ended after #{done} tics, before tic #{n}") if done && done < n
  fail_with.("the run stopped before tic #{n} (#{stopped})") if stopped && frames.size < n
  fail_with.("#{frames.size} frame(s), fewer than the first #{n} asked for") if frames.size < n
  frames = frames.first(n)
end
frames.each_with_index do |f, i|
  fail_with.("frame #{i} is tic #{f[:tic]}; the frames are not tics 0, 1, 2, ... in order") unless f[:tic] == i
  next if opt[:play]
  w = want[i] or fail_with.("tic #{i} is past the recording's #{want.size} frames")
  fail_with.("tic #{i}: view #{f[:view]} full #{f[:full]}, recorded #{w[1]} #{w[2]}") unless f[:view] == w[1] && f[:full] == w[2]
end
if opt[:play]
  fail_with.("the play run wrote a D line; it has no end") if done
  fail_with.("the play run wrote no I line") if ilines.empty?
  last = nil
  ilines.each_with_index do |c, i|
    fail_with.("I line #{i}: dequeued #{c[0]} is not bad + stale + superseded + applied (#{c[1, 4].join(' + ')})") unless c[0] == c[1] + c[2] + c[3] + c[4]
    fail_with.("I line #{i}: a count went down from the line before (#{last.join(',')} to #{c.join(',')})") if last && c.zip(last).any? { |a, b| a < b }
    last = c
  end
  fail_with.("the last I line counts #{last[5]} tics applied, more than the run's #{frames.size + 1} tics") if last[5] > frames.size + 1
  if opt[:expect_bad] && (hi = opt[:expect_bad_max])
    fail_with.("the last I line counts #{last[1]} bad, below the #{opt[:expect_bad]} planted") if last[1] < opt[:expect_bad]
    fail_with.("the last I line counts #{last[1]} bad, above the #{hi} the planted and the late can make") if last[1] > hi
  elsif opt[:expect_bad] && last[1] != opt[:expect_bad]
    fail_with.("the last I line counts #{last[1]} bad, not the #{opt[:expect_bad]} expected")
  end
  fail_with.("the last I line counts #{last[6]} time-outs, not the #{opt[:expect_timeouts]} expected") if opt[:expect_timeouts] && last[6] != opt[:expect_timeouts]
end
unless opt[:partial] || opt[:tics]
  fail_with.("the run stopped (#{stopped})") if stopped
  fail_with.("the run did not end: no `D` line after #{frames.size} frame(s)") unless done
  fail_with.("the run ended after #{done} tics, the recording holds #{want.size}") unless done == want.size
  fail_with.("#{frames.size} frame(s) for #{done} tics") unless frames.size == done
end
cyc = frames.map { |f| f[:cycles] }.sort
stat = if cyc.empty?
         "no frames"
       else
         med = cyc[cyc.size / 2]
         conv = ->(c) { opt[:hz] ? format("%.1f ms", c * 1000.0 / opt[:hz]) : "#{c} cycles" }
         "per tic min #{conv.(cyc.first)}, median #{conv.(med)}, max #{conv.(cyc.last)} (information, not a bound)"
       end
state = if opt[:tics] then "the first #{opt[:tics]} tics read, the rest not"
        elsif done then "ended after #{done} tics"
        else stopped ? "stopped at #{stopped}" : "still running or cut"
        end
net = []
net << "boot #{boots[0]}" unless boots.empty?
unless drops.empty?
  d = drops[0]
  net << "frame channel: #{d[0]} frame(s) and #{d[1]} message(s) dropped#{d[2] ? ", #{d[2]} frame(s) not sent" : ''}"
end
net << "input: dequeued #{ilines.last[0]}, bad #{ilines.last[1]}, stale #{ilines.last[2]}, superseded #{ilines.last[3]}, applied #{ilines.last[4]}, tics applied #{ilines.last[5]}, time-outs #{ilines.last[6]}" if opt[:play]
puts "board-frames: build #{opt[:identity]}, #{frames.size} frame(s), #{opt[:play] ? 'in order' : 'every one the recorded frame'}; #{state}; #{stat}" +
     (net.empty? ? "" : "; #{net.join('; ')}")
