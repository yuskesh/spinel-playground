# Refused: a fiber_def body using a pool (its helpers take only their frames).
require "spinel/core"
state :out, :i32, 1
pool_def :node, max: 2
fiber_def :reader, max: 1
every_ms 10, :tick

def reader(limit)
  Fiber.yield Node.alloc
  limit
end

def tick(out)
  Reader.start(0, 1) unless Reader.alive?(0)
  out[0] = Reader.resume(0, 0)
  0
end
