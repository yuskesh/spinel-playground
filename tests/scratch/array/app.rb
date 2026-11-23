# Decision 0041 stage 2: an array made in a method on the thread context's
# data stack, passed down two calls (fill, then bump) and to a third (total),
# and freed when work returns. One value a release, three releases;
# expect.txt is written by hand: work(n) makes n twos, fill sets the first
# to 10, bump adds 1 to each, total weighs element i by i + 1, and the
# answer is total * 100 + the size.
require "spinel/core"
require "spinel/net"
state :frame, :u8, 4
state :turn, :i32, 1
channel :telemetry, :out, size: 4, depth: 4, uart: true
scratch 256, context: :thread
every_ms 10, :tick

def bump(b, k)
  i = 0
  while i < b.size
    b[i] += k
    i += 1
  end
  0
end

def fill(b, k)
  b[0] = k
  bump(b, 1)
end

def total(b)
  t = 0
  b.each_with_index { |x, i| t += x * (i + 1) }
  t
end

def work(n)
  a = Core::Buffer.i32(n, 2)
  fill(a, 10)
  total(a) * 100 + a.size
end

def tick(frame, turn)
  t = turn[0]
  if t < 3
    n = put_i32(frame, 0, work(t + 2))
    Telemetry.put(frame, n)
    turn[0] = t + 1
  end
  0
end
