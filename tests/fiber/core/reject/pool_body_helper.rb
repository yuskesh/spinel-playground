# Refused: a fiber_def body calling a helper that uses a pool (the helper
# would need the pool's states, which the body's helpers do not take).
require "spinel/core"
state :out, :i32, 1
pool_def :node, max: 2
fiber_def :reader, max: 1
every_ms 10, :tick

def pick
  Node.alloc
end

def reader(limit)
  Fiber.yield pick
  limit
end

def tick(out)
  Reader.start(0, 1) unless Reader.alive?(0)
  out[0] = Reader.resume(0, 0)
  0
end
