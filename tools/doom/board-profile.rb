# frozen_string_literal: true
#
# tools/doom/board-profile.rb — the stage times of examples/doom/core/board/profile.rb, from its console.
#
#   ruby tools/doom/board-profile.rb --console LOG --frames DEMOn.tsv --identity ID --out DIR
#        [--from BYTES] [--hz 240000000] [--partial | --tics N]
#
# The console is decoded as 0014 frames it, from the first boot after --from,
# as tools/doom/board-frames.rb decodes it. The run's F, D and X lines are
# first judged by board-frames.rb itself, with --identity (the build's id,
# which the run must print before its frames): they are framed again,
# unchanged, into DIR/frames.log, and the run counts only if every frame is
# the recorded one and the demo ended (--partial, for a check without a board:
# a run cut short is admitted, as board-frames.rb admits it; --tics N, a run
# the lane stopped reading after its N-th frame, judged on those N frames as
# board-frames.rb --tics judges them, and only the T lines of tics below N
# kept). Its T lines (one per tenth tic) are then written as
#
#   DIR/stages.tsv    one row per sampled tic: each stage in ms (cycles at
#                     --hz), the stages' sum, total less that sum, and the
#                     cycles of total as printed;
#   DIR/summary.txt   per column: samples, min, median, p90, max in ms.
#
# Stages (profile.rb's header says where each starts and ends): input, step,
# cells, render and fnv (the board computes no SHA-256: 0021, the owner's
# decision of 2026-10-21); total is the F line's span; sum = input + step +
# cells + render + fnv; gap = total - sum,
# the clock reads between the stages. Outside total: format (building the F
# line), put (handing the previous tic's line to the channel's ring), wall
# (the previous tic's start to this one's) and stalls (releases in that
# wall that found the ring full). The wire time of a line is not measured:
# the transport thread writes it while the loop sleeps, and no column holds
# it. The percentile is the nearest rank: the value at ceil(0.9 n) in order.
require "optparse"
require "fileutils"
require_relative "../app/lib/core_app/console"

opt = { hz: 240_000_000, from: 0 }
OptionParser.new do |o|
  o.on("--console LOG") { |v| opt[:console] = v }
  o.on("--frames TSV") { |v| opt[:frames] = v }
  o.on("--identity ID") { |v| opt[:identity] = v }
  o.on("--out DIR") { |v| opt[:out] = v }
  o.on("--from BYTES", Integer) { |v| opt[:from] = v }
  o.on("--hz N", Integer) { |v| opt[:hz] = v }
  o.on("--partial") { opt[:partial] = true }
  o.on("--tics N", Integer) { |v| opt[:tics] = v }
end.parse!
abort("board-profile: --partial and --tics are exclusive") if opt[:partial] && opt[:tics]
%i[console frames identity out].each { |k| opt[k] or abort("board-profile: --#{k} is required") }
fail_with = ->(msg) { puts "board-profile: FAIL #{msg}"; exit 1 }
FileUtils.mkdir_p(opt[:out])

raw = File.binread(opt[:console])
banner = "*** Booting Zephyr".b
start = raw.index(banner, opt[:from]) or fail_with.("no `*** Booting Zephyr` after byte #{opt[:from]}")
parsed = CoreApp::Console.parse(raw.byteslice(start..))
loop_frames = +"".b
t_lines = []
parsed.frames.each do |ch, bytes|
  text = bytes.pack("C*")
  if text.start_with?("T ")
    t_lines << text.chomp
  else
    loop_frames << [0xA5, ch, bytes.size].pack("C*") << text
  end
end
# the run's own text (banner, SPC_RUNNING, any fault) goes first, as one block
text = parsed.lines.join("\r\n").b + "\r\n".b
judged = File.join(opt[:out], "frames.log")
File.binwrite(judged, text + loop_frames)
verdict = IO.popen([RbConfig.ruby, File.join(__dir__, "board-frames.rb"), "--console", judged,
                    "--frames", opt[:frames], "--identity", opt[:identity], "--hz", opt[:hz].to_s] + (opt[:partial] ? ["--partial"] : []) +
                    (opt[:tics] ? ["--tics", opt[:tics].to_s] : []), err: %i[child out], &:read)
puts verdict
fail_with.("the run's frames are not the recording's; no stage time is reported") unless $?.success?

names = %w[input step cells render fnv total format put wall stalls]
rows = t_lines.map do |l|
  f = l.split(" ")
  fail_with.("not a T line: #{l.inspect}") unless f.size == 2 + names.size && f[1].match?(/\A\h{16}\z/) && f[2..].all? { |x| x.match?(/\A\h{8}\z/) }
  [f[1].to_i(16), names.zip(f[2..].map { |x| x.to_i(16) }).to_h]
end
# with --tics N, the T lines of the frames that were judged
rows.select! { |t, _| t < opt[:tics] } if opt[:tics]
fail_with.("no T lines") if rows.empty?
rows.each_with_index { |(t, _), i| fail_with.("T line #{i} is tic #{t}, not #{10 * i}") unless t == 10 * i }

ms = ->(c) { c * 1000.0 / opt[:hz] }
cols = %w[input step cells render fnv sum total gap format put wall]
table = rows.map do |t, v|
  d = v.dup
  d["sum"] = %w[input step cells render fnv].sum { |k| v[k] }
  d["gap"] = v["total"] - d["sum"]
  [t, d]
end
File.open(File.join(opt[:out], "stages.tsv"), "w") do |io|
  io.puts((["tic"] + cols.map { |c| "#{c}_ms" } + %w[stalls total_cycles]).join("\t"))
  table.each { |t, d| io.puts(([t] + cols.map { |c| format("%.3f", ms.(d[c])) } + [d["stalls"], d["total"]]).join("\t")) }
end
summary = cols.map do |c|
  # the first sample has no previous tic: its put and wall are not measured
  vs = table.reject { |t, _| t.zero? && %w[put wall].include?(c) }.map { |_, d| d[c] }.sort
  p90 = vs[(0.9 * vs.size).ceil - 1]
  format("%-7s n %4d  min %9.3f  median %9.3f  p90 %9.3f  max %9.3f ms", c, vs.size, ms.(vs.first), ms.(vs[vs.size / 2]), ms.(p90), ms.(vs.last))
end
stalls = table.sum { |_, d| d["stalls"] }
summary << "stalls: #{stalls} release(s) found the ring full over the sampled tics' walls"
summary << "the wire time of a line is not measured (the transport thread writes it while the loop sleeps)"
File.write(File.join(opt[:out], "summary.txt"), summary.join("\n") + "\n")
puts summary
puts "board-profile: #{rows.size} sampled tics, #{File.join(opt[:out], 'stages.tsv')}"
