# frozen_string_literal: true
#
# tests/app/stress/check_wire.rb CONSOLE -- the outbound content check of
# decision 0014 Task 12, over a stress run's raw console.
#
# The telemetry frames are 0xA5, channel 0, length 8, then two little-endian
# words: the sequence number and (sequence * 2654435761) & 0x7fffffff, as
# `produce` in app.rb writes them. Every frame must carry a matching check
# word and a sequence above the previous frame's; a ring that published a
# slot before filling it, or a copy torn by preemption, shows as one or the
# other. Sequences may skip: a full ring refuses a put, and the producer has
# already counted it.
#
# The harness's own lines are printed from interrupt context, which runs to
# completion, so each one lands WHOLE between two bytes of whatever the
# transport thread was writing. They are cut out by their exact shape before
# the frames are read -- counted, so a cut is never silent -- and the frames
# are read up to the report, which ends the run.
#
# Prints one line, `wire frames=N bad_check=N not_rising=N junk=N
# lines=N`, and exits 0; the suite decides what the numbers mean.

LINE = /STRESS(?:_SEEN n=\d+ last=\d+ fails=\d+,\d+,\d+|_FAIL kind=\d+)\r?\n/n

bytes = File.binread(ARGV.fetch(0))
stop = bytes.index("STRESS samples=") || bytes.bytesize
body = bytes.byteslice(0, stop)
lines = body.scan(LINE).size
body = body.gsub(LINE, "")
b = body.bytes
i = b.index(0xA5) || b.size
frames = 0
bad_check = 0
not_rising = 0
junk = 0
last = nil
while i + 3 <= b.size
  unless b[i] == 0xA5 && b[i + 1] == 0 && b[i + 2] == 8
    # not a frame boundary: the boot banner, or text the cut did not know
    junk += 1
    i += 1
    next
  end
  break if i + 11 > b.size # the capture ended inside the last frame
  seq, chk = b[i + 3, 8].pack("C*").unpack("VV")
  frames += 1
  bad_check += 1 unless chk == (seq * 2654435761) & 0x7fffffff
  not_rising += 1 if last && seq <= last
  last = seq
  i += 11
end
puts "wire frames=#{frames} bad_check=#{bad_check} not_rising=#{not_rising} junk=#{junk} lines=#{lines}"
