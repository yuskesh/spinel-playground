# Decision 0041 stage 2: the static capacity refusal. Every size is a
# constant, so the checker composes the worst path (tick's 4 elements under
# more's 2, 24 bytes) and refuses it against the 20 bytes the region holds
# past its offset word (scratch-capacity).
require "spinel/core"
require "spinel/net"
state :out, :i32, 1
scratch 24, context: :thread
every_ms 10, :tick

def more(k)
  b = Core::Buffer.i32(2, 3)
  b[0] + b[1] + k
end

def tick(out)
  a = Core::Buffer.i32(4, 1)
  out[0] = a[3] + more(5)
  0
end
