# Module calls nested in module calls' arguments (the review of 0041 stage
# 3). One value a release, five releases; expect.txt is written by hand.
#   0: Node.free(Node.alloc) frees the slot it was just handed: the count of
#      allocated slots is back to 1 and the next alloc answers that slot
#      again (100 x count + 10 x next + the first slot = 110);
#   1: live? of a receiver-less helper that allocates (it gains the pool's
#      states inside the argument), then a helper whose argument is a
#      module call, inside live? (swap frees its slot and allocates again,
#      so it answers the slot it was given), and as a value, written without
#      parentheses: 1000 + 100 + 10 x 2 + the count of allocated slots, 3.
#      Each alloc runs once: a second one would be CAPACITY;
#   2: free of an expression holding a free, and
#      Keeper.resume(0, Keeper.start(0, 7)) (0035's calls, the same path);
#   3: two allocs in one expression, the freed slots in reverse order;
#   4: nested twice, Node.live?(Node.free(Node.alloc)).
# rewrite.txt is tick as the rewrite must write it, also by hand.
require "spinel/core"
require "spinel/net"
state :frame, :u8, 4
state :turn, :i32, 1
channel :telemetry, :out, size: 4, depth: 4, uart: true
pool_def :node, max: 3
fiber_def :keeper, max: 1
every_ms 10, :tick

def keeper(v)
  Fiber.yield v
  v
end

def pick
  Node.alloc
end

def swap(slot)
  Node.free(slot)
  Node.alloc
end

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
    Node.free(Node.alloc)
    v = (used(0) + used(1) + used(2)) * 100 + Node.alloc * 10 + a
  elsif t == 1
    v = 0
    v = 1000 if Node.live?(pick)
    Node.free(2)
    v += 100 if Node.live?(swap(Node.alloc))
    Node.free(2)
    v += (swap Node.alloc) * 10
    v += used(0) + used(1) + used(2)
  elsif t == 2
    Node.free(Node.free(0) + 1)
    v = Keeper.resume(0, Keeper.start(0, 7)) * 10 + used(0) + used(1)
  elsif t == 3
    v = Node.alloc * 10 + Node.alloc
  elsif t == 4
    Node.free(2)
    v = 0
    v = 10 if Node.live?(Node.free(Node.alloc))
    v += used(0) + used(1) + used(2)
  end
  if t < 5
    n = put_i32(frame, 0, v)
    Telemetry.put(frame, n)
    turn[0] = t + 1
  end
  0
end
