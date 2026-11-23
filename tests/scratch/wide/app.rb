# Decision 0041 stage 2, the review: an :i64 state does not widen the
# body; without `# spinel: int64` it is 32 bits, so the arrays have 4-byte
# elements. A 16-byte region holds the offset word and exactly 3 of them:
# tick's Core::Buffer.i32(3, 7) fits on the target and on the host, where 8-byte
# elements would fail with CAPACITY. out[0] = 21.
require "spinel/core"
state :out, :i64, 1
scratch 16
every_ms 10, :tick

def tick(out)
  a = Core::Buffer.i32(3, 7)
  out[0] = a[0] + a[1] + a[2]
  0
end
