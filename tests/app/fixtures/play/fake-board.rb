# frozen_string_literal: true
#
# tests/app/fixtures/play/fake-board.rb -- the board's side of tools/doom/key-sender.rb,
# on the loopback, for tests/app/play.sh:
#
#   ruby fake-board.rb SENDER_PORT KEYS_PORT SECONDS [SWITCH [PAUSE]]
#
# Binds KEYS_PORT, sends a frame (one wire-version-3 piece, boot id 7) to
# SENDER_PORT every 1/35 s naming the newest K message it took (state 1 once
# one arrived). With SWITCH, after SWITCH seconds it is a new boot, id 9, as
# the board is after a reset, and frames name that id from then on (SWITCH 0:
# never). With PAUSE, it sends no frame for 0.6 s from PAUSE seconds on, the
# same boot before and after. After
# SECONDS it prints, per boot id the messages carried, what it took:
# `boot B took N bad K first F last L session S gap G`, G the longest
# silence between that boot's messages in ms.
require "socket"

sender_port, keys_port, seconds, switch = ARGV.first(4).map { |a| Integer(a, 10) }
switch = nil if switch&.zero?
pause = ARGV[4] && Float(ARGV[4])
s = UDPSocket.new
s.bind("127.0.0.1", keys_port)
now = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
t0 = now.()
t_end = t0 + seconds
per = Hash.new { |h, k| h[k] = { took: 0, bad: 0, first: nil, last: nil, session: nil, last_t: nil, gap: 0.0 } }
seq = 0
session = nil
tic = 0
next_t = now.()
while now.() < t_end
  boot = switch && now.() - t0 >= switch ? 9 : 7
  r, = IO.select([s], nil, nil, [next_t - now.(), 0].max)
  if r
    m, = s.recvfrom(64)
    t = now.()
    b = m.bytesize >= 10 ? m.unpack1("@6L<") : 0
    c = per[b]
    c[:gap] = [c[:gap], t - c[:last_t]].max if c[:last_t]
    c[:last_t] = t
    c[:took] += 1
    if m.bytesize == 17 && m.getbyte(0) == 0x4B && (m.getbyte(16) & 0xFC).zero?
      c[:session], q = m.unpack("@2L<@10L<")
      c[:first] ||= q
      c[:last] = q
      if b == boot
        session = c[:session]
        seq = q
      end
    else
      c[:bad] += 1
    end
  end
  next unless now.() >= next_t
  if pause && (now.() - t0).between?(pause, pause + 0.6)
    next_t += 1.0 / 35
    next
  end
  piece = [0x43, 3, boot, tic, 0, 50, session || 0, session ? seq : 0, session ? 1 : 0].pack("CCL<L<CCL<L<C") + ("\0" * 1280)
  s.send(piece, 0, "127.0.0.1", sender_port)
  tic += 1
  next_t += 1.0 / 35
end
per.sort.each { |b, c| puts "boot #{b} took #{c[:took]} bad #{c[:bad]} first #{c[:first]} last #{c[:last]} session #{c[:session]} gap #{(c[:gap] * 1000).round}" }
