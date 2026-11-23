# Refused: a pool and a fiber kind with one name.
require "spinel/core"
state :out, :i32, 1
fiber_def :node, max: 1
pool_def :node, max: 2
every_ms 10, :tick

def node
  Fiber.yield 0
  0
end

def tick(out)
  out[0] = 0
  0
end
