# Two pools and helpers called without parentheses, nested (the second
# review of 0041 stage 3): in `outer inner A.alloc` both calls close at one
# offset, and each must gain its own pool's states. inner and outer are
# defined in one order, outer2 and inner2 in the other. One value a
# release, five releases; expect.txt and rewrite.txt are written by hand.
#   0: inner frees its A slot and allocates it again, outer allocates a B
#      slot: 100 x the slot (0) + 10 x A's count (1) + B's count (2) = 12;
#   1: the same through outer2 and inner2: 100 x 1 + 10 x 2 + 3 = 123;
#   2: A.free(0): 10 x live?(0) + live?(1) = 1;
#   3: A.alloc answers the freed slot, 0;
#   4: B's third slot is allocated: 1.
require "spinel/core"
require "spinel/net"
state :frame, :u8, 4
state :turn, :i32, 1
channel :telemetry, :out, size: 4, depth: 4, uart: true
pool_def :a, max: 2
pool_def :b, max: 3
every_ms 10, :tick

def inner(slot)
  A.free(slot)
  A.alloc
end

def outer(slot)
  B.alloc
  slot
end

def outer2(slot)
  B.alloc
  slot
end

def inner2(slot)
  A.free(slot)
  A.alloc
end

def ua(slot)
  r = 0
  r = 1 if A.live?(slot)
  r
end

def ub(slot)
  r = 0
  r = 1 if B.live?(slot)
  r
end

def tick(frame, turn)
  t = turn[0]
  v = -1
  if t == 0
    B.alloc
    x = outer inner A.alloc
    v = x * 100 + (ua(0) + ua(1)) * 10 + ub(0) + ub(1) + ub(2)
  elsif t == 1
    y = outer2 inner2 A.alloc
    v = y * 100 + (ua(0) + ua(1)) * 10 + ub(0) + ub(1) + ub(2)
  elsif t == 2
    A.free(0)
    v = ua(0) * 10 + ua(1)
  elsif t == 3
    v = A.alloc
  elsif t == 4
    v = ub(2)
  end
  if t < 5
    n = put_i32(frame, 0, v)
    Telemetry.put(frame, n)
    turn[0] = t + 1
  end
  0
end
