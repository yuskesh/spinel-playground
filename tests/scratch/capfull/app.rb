# Decision 0041 stage 2: a planted capacity control. The thread context's
# data stack holds 24 bytes: the 4-byte offset word and 5 i32 elements.
# tick makes 4 and calls more(2), which asks for 2: one element past the
# region, so the release fails with CAPACITY (status 4) at more's
# Core::Buffer, on every run, before anything is written. The size is more's
# parameter, so no static total exists and the region's guard decides.
require "spinel/core"
require "spinel/net"
state :out, :i32, 1
scratch 24, context: :thread
every_ms 10, :tick

def more(k)
  b = Core::Buffer.i32(k, 3)
  b[0] + b[1]
end

def tick(out)
  a = Core::Buffer.i32(4, 1)
  out[0] = a[3] + more(2)
  0
end
