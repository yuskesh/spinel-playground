# Decision 0041 stage 3: a pool of 3 slots allocated, freed and reused. One
# value a release, five releases; expect.txt is written by hand from the
# order of reuse (the most recently freed slot first, then the lowest slot
# never handed out).
require "spinel/core"
require "spinel/net"
state :frame, :u8, 4
state :turn, :i32, 1
channel :telemetry, :out, size: 4, depth: 4, uart: true
pool_def :node, max: 3
every_ms 10, :tick

def used(slot)
  r = 0
  r = 1 if Node.live?(slot)
  r
end

def tick(frame, turn)
  t = turn[0]
  v = -1
  if t == 0
    a = Node.alloc
    b = Node.alloc
    v = a * 10 + b
  elsif t == 1
    Node.free(0)
    v = used(0) * 10 + used(1)
  elsif t == 2
    c = Node.alloc
    d = Node.alloc
    v = c * 10 + d
  elsif t == 3
    Node.free(2)
    Node.free(1)
    e = Node.alloc
    v = e * 10 + used(2)
  elsif t == 4
    f = Node.alloc
    v = f * 10 + used(0) + used(1) + used(2)
  end
  if t < 5
    n = put_i32(frame, 0, v)
    Telemetry.put(frame, n)
    turn[0] = t + 1
  end
  0
end
