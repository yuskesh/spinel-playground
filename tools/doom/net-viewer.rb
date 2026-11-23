# frozen_string_literal: true
#
# tools/doom/net-viewer.rb -- shows the frames the board sends over UDP, and
# checks each one against the board's own console (decision 0024).
#
#   ruby tools/doom/net-viewer.rb [--port 5029] [--bind ADDR] [--record FILE]
#        [--idle SECONDS] [--tics N] ...      live: listen for the board
#   ruby tools/doom/net-viewer.rb --replay FILE ...   a recording instead
#
#   the rest, either way:
#        [--console LOG]  the board run's console log: judge the digests
#        [--show ffplay|none] [--ppm-dir DIR]  where the frames go
#        [--aspect 1:1|4:3|fill] [--scale N] [--size WxH]
#        [--window N] [--log TSV] [--max-loss N]
#
# The wire, the reassembly and what counts as a drop are tools/doom/
# net_frames.rb's. Listening, the viewer binds --bind (any address) on --port
# (5029, linuxdoom's DOOMPORT) and runs until --idle seconds pass with no
# datagram after the first (5), until --tics frames have been closed, or
# until interrupted. A child process does nothing but receive, appending
# each datagram to a recording (--record FILE, or a temporary file deleted
# at the end) that this process reads behind it, so that digesting and
# showing cannot leave the socket unread long enough for the kernel to drop
# what the board sent; it asks for an 8 MB receive buffer and prints what it
# got. --record's file is in the form --replay reads, so a run can be judged
# again.
#
# SHOWING. Each complete frame goes through its boot's palette (the latest
# 'P' message, resent every second; a frame before the first is not shown,
# and is counted as before the palette) and is scaled by nearest neighbour:
# --aspect 1:1 keeps the pixels square (320x200 times --scale, 2), 4:3
# stretches the rows as a CRT showed them (320x240 times --scale), fill is
# exactly --size WxH. --show ffplay pipes the frames to ffplay as PPM images;
# --ppm-dir writes them as tic%06d.ppm. Showing runs beside the receiving, on
# the latest complete frame: a frame it has no time for is not shown, and is
# still digested and counted.
#
# JUDGING. Every complete frame's view and full FNV-1a 64 are computed here.
# With --console, each is compared with the board's `F` line for its tic: the
# same board run, so this is no oracle (0024, Validation). The console is one
# boot's: the boot its `B` line names is judged, and the others are only
# counted. The summary gives
#   * the datagrams, the bad ones by reason, and per boot: the palette, the
#     frames complete (and how many before the palette), incomplete (and the
#     pieces they lack, and those whose pieces disagree on the input) and
#     absent, the late, duplicate and backwards pieces, the input the
#     complete frames carry (none, held, released; decision 0025 point 15),
#     and the latest `S` (the M7's counts);
#   * against the console: matched, differing, and complete frames its log
#     has no `F` line for (a log cut early);
#   * missing frames: the console's tics with no complete frame of its boot;
#     and, from the board's `N <frames dropped> <messages dropped> <frames
#     not sent>` line, what it dropped and chose not to send, so that the
#     network lost the difference (NetFrames::Console#unsent_frames).
# --log writes one row per closed frame: boot, tic, view, full, and
# complete, incomplete:<pieces missing>, mismatch (every piece, disagreeing
# on the input) or the console's verdict.
#
# The exit status is 1 when a datagram was bad, when a boot's tics went
# backwards (two boots sharing an id), or when an `S` does not add up; and,
# with --console, when it has no `B` line or two, when its boot sent nothing
# here, when a frame's digests differ from its `F` line, when no frame
# matched one (a run that received nothing, or nothing the console knows,
# shows nothing), or when the network lost more than --max-loss frames.
# --max-loss is 0 unless given, and the loss is judged only when the console
# has an `N` line: without one the board's own drops are not known. 2 on a
# usage error; 0 otherwise.
require "optparse"
require "socket"
require "tmpdir"
require_relative "net_frames"

opt = { port: 5029, bind: "0.0.0.0", idle: 5.0, window: 8, show: "none", aspect: "1:1", scale: 2 }
OptionParser.new do |o|
  o.on("--port N", Integer) { |v| opt[:port] = v }
  o.on("--bind ADDR") { |v| opt[:bind] = v }
  o.on("--replay FILE") { |v| opt[:replay] = v }
  o.on("--record FILE") { |v| opt[:record] = v }
  o.on("--idle SECONDS", Float) { |v| opt[:idle] = v }
  o.on("--tics N", Integer) { |v| opt[:tics] = v }
  o.on("--console LOG") { |v| opt[:console] = v }
  o.on("--show WHAT") { |v| opt[:show] = v }
  o.on("--ppm-dir DIR") { |v| opt[:ppm_dir] = v }
  o.on("--aspect A") { |v| opt[:aspect] = v }
  o.on("--scale N", Integer) { |v| opt[:scale] = v }
  o.on("--size WxH") { |v| opt[:size] = v }
  o.on("--window N", Integer) { |v| opt[:window] = v }
  o.on("--log TSV") { |v| opt[:log] = v }
  o.on("--max-loss N", Integer) { |v| opt[:max_loss] = v }
end.parse!
usage = ->(msg) { warn "net-viewer: #{msg}"; exit 2 }
usage.("--show #{opt[:show]}: one of ffplay, none") unless %w[ffplay none].include?(opt[:show])
usage.("--replay and --record together: a replay receives nothing to record") if opt[:replay] && opt[:record]
usage.("--scale #{opt[:scale]} is not 1 or more") unless opt[:scale] >= 1
size = nil
if opt[:size]
  m = opt[:size].match(/\A(\d+)x(\d+)\z/) or usage.("--size #{opt[:size]} is not WxH")
  size = [m[1].to_i, m[2].to_i]
  usage.("--size #{opt[:size]} has a zero side") if size.include?(0)
end
out_w, out_h = begin
  NetFrames::Scaler.size_for(opt[:aspect], opt[:scale], size)
rescue ArgumentError => e
  usage.(e.message)
end
console = opt[:console] && NetFrames.console(File.binread(opt[:console]))

# showing, beside the receiving: a slot holding the latest complete frame
showing = opt[:show] == "ffplay" || opt[:ppm_dir]
shown = 0
latest = nil
lock = Mutex.new
ready = ConditionVariable.new
stop = false
shower = nil
if showing
  scaler = NetFrames::Scaler.new(out_w, out_h)
  Dir.mkdir(opt[:ppm_dir]) if opt[:ppm_dir] && !Dir.exist?(opt[:ppm_dir])
  pipe = if opt[:show] == "ffplay"
           begin
             IO.popen(["ffplay", "-loglevel", "error", "-window_title", "DOOM (board)",
                       "-f", "image2pipe", "-c:v", "ppm", "-i", "-"], "wb")
           rescue SystemCallError => e
             usage.("--show ffplay: #{e.message}")
           end
         end
  shower = Thread.new do
    loop do
      got = lock.synchronize do
        ready.wait(lock) while latest.nil? && !stop
        f = latest
        latest = nil
        f
      end
      break unless got

      frame, palette = got
      img = scaler.ppm(frame[:screen], palette)
      File.binwrite(File.join(opt[:ppm_dir], format("tic%06d.ppm", frame[:tic])), img) if opt[:ppm_dir]
      if pipe
        begin
          pipe.write(img)
        rescue Errno::EPIPE
          pipe = nil
        end
      end
      shown += 1
    end
  end
end

asm = NetFrames::Assembler.new(window: opt[:window])
closed = []
take = lambda do |frames|
  frames.each do |f|
    closed << { boot: f[:boot], tic: f[:tic], missing: f[:missing], mismatch: f[:mismatch], digests: f[:screen] && NetFrames.digests(f[:screen]) }
    palette = asm.boot(f[:boot]).palette
    next unless showing && f[:screen] && palette

    lock.synchronize do
      latest = [f, palette]
      ready.signal
    end
  end
end

if opt[:replay]
  begin
    NetFrames::Recording.each(File.binread(opt[:replay])) { |d| take.(asm.feed(d)) }
  rescue ArgumentError => e
    usage.("--replay #{opt[:replay]}: #{e.message}")
  end
else
  # A child process only receives, appending each datagram to the recording
  # (a temporary file without --record); this process reads the recording
  # behind it. Digesting and showing then cannot hold the socket unread long
  # enough for the kernel to drop datagrams the board did send.
  sock = UDPSocket.new
  sock.bind(opt[:bind], opt[:port])
  begin
    sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 8 << 20)
  rescue SystemCallError
    nil
  end
  rcvbuf = sock.getsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF).int
  path = opt[:record] || File.join(Dir.tmpdir, "net-viewer-#{Process.pid}.rec")
  File.binwrite(path, "")
  warn "net-viewer: listening on #{opt[:bind]}:#{opt[:port]} (receive buffer #{rcvbuf} B), recording to #{path}"
  receiver = fork do
    out = File.open(path, "ab")
    started = false
    begin
      loop do
        ok = IO.select([sock], nil, nil, started ? opt[:idle] : nil)
        break unless ok

        d, = sock.recvfrom(65_535)
        started = true
        out.syswrite([d.bytesize].pack("L<") + d.b)
      end
    rescue Interrupt, SignalException
      nil
    end
    exit!(0)
  end
  sock.close
  reader = NetFrames::Recording::Reader.new
  begin
    File.open(path, "rb") do |io|
      loop do
        chunk = io.read_nonblock(1 << 20, exception: false)
        if chunk.is_a?(String)
          reader.feed(chunk) { |d| take.(asm.feed(d)) }
          break if opt[:tics] && closed.size >= opt[:tics]
        elsif Process.waitpid(receiver, Process::WNOHANG)
          receiver = nil
          rest = io.read
          reader.feed(rest) { |d| take.(asm.feed(d)) } if rest && !rest.empty?
          break
        else
          sleep 0.002
        end
      end
    end
  rescue Interrupt
    nil
  ensure
    if receiver
      Process.kill("TERM", receiver)
      Process.wait(receiver)
    end
    File.delete(path) unless opt[:record]
  end
  warn "net-viewer: the recording ends inside a datagram (#{reader.pending} B)" if reader.pending.positive?
end
take.(asm.finish)
if shower
  lock.synchronize do
    stop = true
    ready.signal
  end
  shower.join
  pipe&.close
end

st = asm.stats
bad = asm.bad_reasons.map { |r, n| "#{n} #{r}" }.join(", ")
puts "net-viewer: #{st[:datagrams]} datagram(s), #{st[:bad]} bad#{bad.empty? ? '' : " (#{bad})"}; #{asm.boots.size} boot(s)"
fail = st[:bad].positive?
hexid = ->(id) { format("%08x", id) }
asm.boots.each_value do |b|
  bs = b.stats
  mine = closed.select { |f| f[:boot] == b.id }
  pal = if b.palette
          "palette received (#{bs[:palettes]} time(s)#{bs[:palette_changed].positive? ? ", #{bs[:palette_changed]} changed" : ''})"
        else
          "palette NOT received"
        end
  puts "net-viewer: boot #{hexid.(b.id)}: #{bs[:datagrams]} datagram(s), #{pal}; frames: " \
       "#{mine.count { |f| !f[:missing] }} complete (#{bs[:before_palette]} before the palette), " \
       "#{mine.count { |f| f[:missing] }} incomplete (#{bs[:pieces_missing]} piece(s) missing), #{b.absent.size} absent; " \
       "#{bs[:late]} late, #{bs[:duplicates]} duplicate, #{bs[:backwards]} backwards"
  puts "net-viewer: boot #{hexid.(b.id)}: input of the complete frames: #{bs[:input_0]} none, #{bs[:input_1]} held, " \
       "#{bs[:input_2]} released by the time-out; #{bs[:input_mismatch]} incomplete frame(s) whose pieces disagree on it"
  if (c = b.stream)
    puts "net-viewer: boot #{hexid.(b.id)}: the M7's latest S: tic #{c[:tic]}, #{c[:sent]} sent, #{c[:not_sent]} not sent, " \
         "#{c[:dropped]} dropped, #{c[:messages_dropped]} message(s) dropped"
  end
  if bs[:backwards].positive?
    puts "net-viewer: FAIL boot #{hexid.(b.id)}: #{bs[:backwards]} piece(s) of a tic going backwards " \
         "(first tic #{b.backwards.first}): two boots share this id"
    fail = true
  end
  if bs[:stream_inconsistent].positive?
    puts "net-viewer: FAIL boot #{hexid.(b.id)}: #{bs[:stream_inconsistent]} S message(s) whose sent, not sent and dropped " \
         "do not add up to the latest tic + 1"
    fail = true
  end
end
puts "net-viewer: #{shown} frame(s) shown" if showing
verdict = {}
if console
  judged = console.boot
  if console.boots.empty?
    puts "net-viewer: FAIL the console has no B line, so its boot is not known"
    fail = true
  elsif console.boots.size > 1
    puts "net-viewer: FAIL the console has #{console.boots.size} B lines; one console is one boot"
    fail = true
  elsif !asm.boots.key?(judged)
    puts "net-viewer: FAIL the console's boot #{hexid.(judged)} sent no datagram here"
    fail = true
  end
  others = asm.boots.keys - [judged]
  puts "net-viewer: not judged, not the console's boot: #{others.map { |i| hexid.(i) }.join(', ')}" unless others.empty?
  complete = closed.select { |f| f[:boot] == judged && !f[:missing] }
  differ = []
  unlisted = 0
  complete.each do |f|
    want = console.frames[f[:tic]]
    if want.nil?
      unlisted += 1
      verdict[[f[:boot], f[:tic]]] = "no-F-line"
    elsif want == f[:digests]
      verdict[[f[:boot], f[:tic]]] = "match"
    else
      differ << f
      verdict[[f[:boot], f[:tic]]] = "differs"
    end
  end
  got = complete.to_h { |f| [f[:tic], true] }
  missing = console.frames.keys.reject { |t| got[t] }.size
  matched = complete.size - differ.size - unlisted
  puts "net-viewer: against the console's #{console.frames.size} F line(s)#{judged ? " (boot #{hexid.(judged)})" : ''}: " \
       "#{matched} match, #{differ.size} differ, #{unlisted} complete frame(s) with no F line"
  differ.first(5).each do |f|
    puts "net-viewer: DIFFERS tic #{f[:tic]}: view #{f[:digests][0]} full #{f[:digests][1]}, " \
         "the board's #{console.frames[f[:tic]].join(' ')}"
  end
  puts "net-viewer: FAIL no frame matched its F line" if matched.zero?
  fail ||= !differ.empty? || matched.zero?
  if (unsent = console.unsent_frames)
    loss = missing - unsent
    puts "net-viewer: #{missing} frame(s) missing here; the board dropped #{console.dropped_frames} frame(s) " \
         "(#{console.dropped_messages} message(s)) and did not send #{console.not_sent} by choice, so the network lost #{loss}"
    limit = opt[:max_loss] || 0
    puts "net-viewer: FAIL the network lost #{loss} frame(s), more than --max-loss #{limit}" if loss > limit
    fail ||= loss > limit
  else
    puts "net-viewer: #{missing} frame(s) missing here; the console has no N line, so the board's drops are not known"
  end
end
if opt[:log]
  File.open(opt[:log], "w") do |io|
    io.puts "#boot\ttic\tview\tfull\tstatus"
    closed.sort_by { |f| [f[:boot], f[:tic]] }.each do |f|
      v, full = f[:digests] || ["-", "-"]
      status = if f[:mismatch] then "mismatch"
               elsif f[:missing] then "incomplete:#{f[:missing]}"
               else verdict[[f[:boot], f[:tic]]] || "complete"
               end
      io.puts [hexid.(f[:boot]), f[:tic], v, full, status].join("\t")
    end
  end
end
exit(fail ? 1 : 0)
