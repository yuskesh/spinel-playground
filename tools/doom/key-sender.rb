# frozen_string_literal: true
#
# tools/doom/key-sender.rb -- a scripted controller for examples/doom/core/board/play.rb
# (decision 0025), in place of a person at net_view's keyboard.
#
#   ruby tools/doom/key-sender.rb --keys-port N [--frames-port 5029] [--bind ADDR]
#        [--seconds S] [--bad K] [--gap MS] [--wait S] [--session ID] --out DIR
#
# It is the frames' receiver and the keys' sender at once, on one socket
# bound to --frames-port, as net_view is with --keys (decision 0025 point 3):
#
#   1. it waits (at most --wait seconds) for the first valid frame-wire
#      version 3 datagram, and takes the board's boot id from it and the
#      board's address from its source -- the lane never needs the board's
#      DHCP address. It follows the newest boot as net_view does: a
#      datagram of a boot id not seen before switches the keys to that boot
#      and its source, and an older boot is never gone back to;
#   2. it then sends K messages to that address at --keys-port, 35 a second
#      for --seconds: sequence numbers from 1, advancing by one on every send;
#      the mask walks through up, left, right, fire, use and none, a second
#      each; --bad K of them, spread over the run, have a reserved bit set
#      (the board must count each as bad, using none); one silence of --gap
#      ms in the middle, longer than the board's 500 ms time-out, so the
#      board must count one time-out (--gap 0: none); and an all-released
#      message last. When the boot changes, the script starts again from the
#      top for the new boot, so the boot that is judged receives all of it;
#      the sequence numbers go on rising, never reset (the coordinator, 2026-10-23);
#   3. it receives the frames all the while, and for one more second after.
#      When no datagram of the boot it sends to has come for 200 ms, it sends
#      nothing until one comes: from a new boot it starts the script again,
#      from the same boot it goes on where it stopped (each such stop is a
#      pause). So only the few messages sent before it saw the silence can
#      reach a board that reset.
#
# DIR/sent.tsv records each message (boot, sequence, the time sent, the mask,
# bad or not), DIR/frames.tsv each frame's first piece (boot, tic, session,
# sequence, input state, the time received). The summary on stdout gives a
# line per switch of boot -- the messages sent to the old boot after its last
# datagram arrived, the only ones the new boot can have received with the
# old id (`late`) -- a line per boot -- what was sent to it and the frames it
# sent -- then the last boot's line with its late count, and, for the
# sequence numbers that boot's frames name
# with input state 1, the span from the send to the first frame received
# naming it -- once per sequence number, as decision 0025 point 15 says; a
# measurement, not when anything appeared on a screen, and not a bound.
#
# Exit 2 on a usage error, 3 when no frame arrived in --wait seconds, at
# the start or after a pause.
require "optparse"
require "socket"
require "fileutils"

opt = { frames_port: 5029, bind: "0.0.0.0", seconds: 10, bad: 3, gap: 1500, wait: 120, session: nil }
OptionParser.new do |o|
  o.on("--keys-port N", Integer) { |v| opt[:keys_port] = v }
  o.on("--frames-port N", Integer) { |v| opt[:frames_port] = v }
  o.on("--bind ADDR") { |v| opt[:bind] = v }
  o.on("--seconds S", Integer) { |v| opt[:seconds] = v }
  o.on("--bad K", Integer) { |v| opt[:bad] = v }
  o.on("--gap MS", Integer) { |v| opt[:gap] = v }
  o.on("--wait S", Integer) { |v| opt[:wait] = v }
  o.on("--session ID", Integer) { |v| opt[:session] = v }
  o.on("--out DIR") { |v| opt[:out] = v }
end.parse!
usage = ->(m) { warn "key-sender: #{m}"; exit 2 }
usage.("--keys-port and --out are required") unless opt[:keys_port] && opt[:out]
usage.("--gap #{opt[:gap]} ms is not above the board's 500 ms time-out") if opt[:gap].positive? && opt[:gap] <= 500
FileUtils.mkdir_p(opt[:out])

BITS = { "up" => 2, "left" => 1, "right" => 0, "fire" => 6, "use" => 7 }.freeze
WALK = [["up"], ["left"], ["right"], ["fire"], ["use"], []].freeze
TIC = 1.0 / 35
now = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
session = opt[:session] || (Random.new.rand(1..0xffff_ffff))

sock = UDPSocket.new
sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
sock.bind(opt[:bind], opt[:frames_port])

frames = Hash.new { |h, k| h[k] = {} } # boot => {tic => [session, seq, state, t]}
boots = []    # in the order their first datagram arrived; the last is the newest
bad_frames = 0
board = nil
boot = nil
switched = false
last_seen = {} # boot => when its last datagram arrived
switches = []  # [old boot, new boot, when the old one's last datagram arrived]
receive = lambda do |until_t|
  loop do
    left = until_t - now.()
    break if left <= 0
    r, = IO.select([sock], nil, nil, left)
    break unless r
    d, from = sock.recvfrom(2048)
    t = now.()
    if d.bytesize < 6 || d.getbyte(1) != 3 || d.unpack1("@2L<").zero?
      bad_frames += 1
      next
    end
    id = d.unpack1("@2L<")
    unless boots.include?(id)
      # a boot not seen before is the newest, as net_view follows it: the
      # keys go to it from now on, and an older one is never gone back to
      switched = !boot.nil?
      switches << [boot, id, last_seen[boot]] if switched
      boots << id
      board = from[3]
      boot = id
    end
    last_seen[id] = t
    next unless d.getbyte(0) == 0x43 && d.bytesize == 1301
    frames[id][d.unpack1("@6L<")] ||= d.unpack("@12L<L<C") + [t]
  end
end

deadline = now.() + opt[:wait]
receive.([now.() + 0.1, deadline].min) while board.nil? && now.() < deadline
if board.nil?
  warn "key-sender: no frame-wire version 3 datagram on port #{opt[:frames_port]} in #{opt[:wait]} s"
  exit 3
end

n = (opt[:seconds] * 35).to_i
bad_at = opt[:bad].positive? ? (1..opt[:bad]).map { |i| i * n / (opt[:bad] + 1) } : []
sent = [] # [boot, seq, t, mask, bad]
seq = 0
t0 = now.()
send_k = lambda do |mask, bad|
  seq = (seq + 1) & 0xffff_ffff
  m = [0x4B, 1, session, boot, seq, mask & 0xff, (mask >> 8) & 0xff, ((mask >> 16) & 0x03) | (bad ? 0x04 : 0)].pack("CCL<L<L<CCC")
  sock.send(m, 0, board, opt[:keys_port])
  sent << [boot, seq, now.() - t0, mask, bad ? 1 : 0]
end
# THE SCRIPT, FROM THE TOP FOR EVERY NEW BOOT (the coordinator, 2026-10-23): the boot
# that is judged must receive all of it, its planted bad messages and its
# gap included. The sequence numbers go on rising across boots.
gaps = Hash.new(0)
pauses = Hash.new(0)
SILENCE = 0.2
lost = false
give_up = now.() + opt[:wait]
loop do
  switched = false
  k = 0
  gap_at = opt[:gap].positive? ? n / 2 : nil
  next_t = now.()
  while k < n
    if gap_at && k == gap_at
      next_t += opt[:gap] / 1000.0
      gap_at = nil
      gaps[boot] += 1
    end
    receive.(next_t)
    break if switched
    # FRAMES STOPPED: no datagram of this boot for SILENCE, as when the board
    # resets. Nothing is sent until one comes: from a new boot the script
    # starts again from the top, from this boot it goes on where it stopped
    # (the coordinator, 2026-10-23). So few messages go to a boot that is gone.
    if now.() - last_seen[boot] > SILENCE
      pauses[boot] += 1
      at = last_seen[boot]
      receive.([now.() + 0.05, give_up].min) while !switched && last_seen[boot] == at && now.() < give_up
      break if switched
      if last_seen[boot] == at
        lost = true
        break
      end
      next_t = now.()
      give_up = now.() + opt[:wait]
    end
    keys = WALK[(k / 35) % WALK.size]
    send_k.(keys.sum { |x| 1 << BITS.fetch(x) }, bad_at.include?(k))
    k += 1
    next_t += TIC
  end
  next if switched
  break if lost
  send_k.(0, false)
  receive.(now.() + 1.0)
  break unless switched
end

File.write(File.join(opt[:out], "sent.tsv"), "#boot\tseq\tt\tmask\tbad\n" + sent.map { |r| format("%08x\t%d\t%.6f\t%d\t%d\n", *r) }.join)
File.write(File.join(opt[:out], "frames.tsv"),
           "#boot\ttic\tsession\tseq\tstate\tt\n" +
           boots.flat_map { |b| frames[b].sort.map { |tic, (s, q, st, t)| format("%08x\t%d\t%d\t%d\t%d\t%.6f\n", b, tic, s, q, st, t - t0) } }.join)
# LATE: at each switch, the K messages sent to the old boot after its last
# datagram arrived. Only those can have reached the new boot -- its M33
# receives before its first frame tells this sender of it -- where they are
# bad: a lane's bound on the bad count above the planted ones (the coordinator,
# 2026-10-23).
late = {}
switches.each do |old, new, at|
  late[new] = sent.count { |r| r[0] == old && (at.nil? || r[2] + t0 > at) }
  puts "key-sender: switched from boot #{format('%08x', old)} to boot #{format('%08x', new)}: " \
       "#{late[new]} message(s) sent to #{format('%08x', old)} after its last datagram arrived"
end
# per boot: what was sent to it and what came from it
boots.each do |b|
  mine = sent.select { |r| r[0] == b }
  fs = frames[b].values
  states = fs.group_by { |v| v[2] }.transform_values(&:size).sort.map { |st, c| "state #{st}: #{c}" }.join(", ")
  puts "key-sender: boot #{format('%08x', b)}: sent #{mine.size} (bad #{mine.count { |r| r[4] == 1 }}, gaps #{gaps[b]}, paused #{pauses[b]}), " \
       "frames received #{fs.size}#{states.empty? ? '' : " (#{states})"}#{b == boot ? ', the last boot: the script ran whole' : ', left for a newer boot'}"
end
sent_at = sent.select { |r| r[0] == boot && r[4].zero? }.to_h { |_, q, t, _, _| [q, t] }
seen = {}
frames[boot].sort.each do |_tic, (s, q, st, t)|
  next unless st == 1 && s == session && sent_at[q] && !seen.key?(q)
  seen[q] = (t - t0) - sent_at[q]
end
spans = seen.values.sort
span = if spans.empty?
         "no frame of the last boot named a sequence number this sender sent"
       else
         format("send to first frame received, over %d sequence numbers of the last boot: min %.1f ms, median %.1f ms, max %.1f ms (a measurement, not a bound)",
                spans.size, spans.first * 1000, spans[spans.size / 2] * 1000, spans.last * 1000)
       end
mine = sent.select { |r| r[0] == boot }
puts "key-sender: board #{board}, boot #{format('%08x', boot)} (the last of #{boots.size}), session #{format('%08x', session)}; " \
     "sent #{mine.size} to it (bad #{mine.count { |r| r[4] == 1 }}, gaps #{gaps[boot]}, late #{late.fetch(boot, 0)}), #{sent.size} in all; " \
     "bad datagrams #{bad_frames}; #{span}"
if lost
  warn "key-sender: no datagram of boot #{format('%08x', boot)} or a newer one for #{opt[:wait]} s after it stopped"
  exit 3
end
