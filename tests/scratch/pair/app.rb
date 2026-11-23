# Decision 0041 stage 2: one array in each of two contexts at once. The
# thread entry's probe makes a = [0, 0, 0], writes a[0] = 1, then spins (at most
# 200000 times) until the interrupt entry, every millisecond, has run,
# and writes a[1] = 2. Each interrupt release makes its own array of three
# nines on the interrupt context's data stack. The thread's array is intact
# when its value, seen * 1000 + a[0] * 100 + a[1] * 10 + a[2], is 1120 (seen
# is 1 when an interrupt release landed between the two writes); a shared
# stack would have put nines in it. expect.txt is written by hand. Not run
# on the host: the host runner releases one entry at a time, so no interrupt
# lands inside a thread release there.
require "spinel/core"
require "spinel/net"
state :frame, :u8, 4
state :turn, :i32, 1
state :beats, :i32, 1
channel :telemetry, :out, size: 4, depth: 4, uart: true
scratch 64, context: :thread
scratch 64, context: :interrupt
every_ms 50, :tick
every_ms 1, :beat, context: :interrupt

def beat(beats)
  b = Core::Buffer.i32(3, 9)
  beats[0] = beats[0] + b[0] - 8
  0
end

def hold(a, beats)
  first = beats[0]
  i = 0
  while i < 200000 && beats[0] == first
    i += 1
  end
  r = 0
  r = 1 if beats[0] != first
  r
end

def probe(beats)
  a = Core::Buffer.i32(3, 0)
  a[0] = 1
  seen = hold(a, beats)
  a[1] = 2
  seen * 1000 + a[0] * 100 + a[1] * 10 + a[2]
end

def tick(frame, turn, beats)
  t = turn[0]
  if t < 2
    n = put_i32(frame, 0, probe(beats))
    Telemetry.put(frame, n)
    turn[0] = t + 1
  end
  0
end
