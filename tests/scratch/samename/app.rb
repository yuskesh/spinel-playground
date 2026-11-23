# Decision 0041 stage 2, the review: an application method that shares
# a name with one of the host runner's own (Scratch#make) must not free the
# arrays. The thread context's data stack holds 16 bytes: the offset word
# and 3 i32 elements. tick makes out[0] + 3 = 3 of them, then 1 more, which
# is CAPACITY (status 4) at release 1. make is never called.
require "spinel/core"
require "spinel/net"
state :out, :i32, 1
scratch 16, context: :thread
every_ms 10, :tick

def make
  0
end

def tick(out)
  n = out[0] + 3
  a = Core::Buffer.i32(n, 0)
  b = Core::Buffer.i32(1, 0)
  out[0] = a.size + b.size
  0
end
