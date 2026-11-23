# Refused: one kind driven from two contexts (decision 0035 stage 2, one owning context).
require "spinel/core"
state :out, :i32, 1
fiber_def :reader, max: 2
every_ms 10, :tick
every_ms 10, :fast, context: :interrupt

def reader(limit)
  i = 0
  while i < limit
    Fiber.yield i
    i += 1
  end
  limit
end

def tick(out)
  Reader.start(0, 3) unless Reader.alive?(0)
  0
end

def fast
  Reader.resume(0, 0) if Reader.alive?(0)
  0
end
