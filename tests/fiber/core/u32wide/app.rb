# A u32 value at 2^31 is never carried into an i32 frame field: on the 32-bit
# targets the arithmetic that makes it fails with ARITHMETIC first.
require "spinel/core"
state :big, :u32, 1
state :out, :u32, 1
fiber_def :reader, max: 1
every_ms 10, :tick

def reader(v)
  Fiber.yield 0
  v
end

def tick(big, out)
  big[0] = 2147483647
  big[0] += 1
  Reader.start(0, big[0]) unless Reader.alive?(0)
  out[0] = Reader.resume(0, 0)
  0
end
