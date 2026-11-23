# Misuse: start on a live slot (the second release). It is BOUNDS (decision 0035 stage 2).
require "spinel/core"
state :out, :i32, 1
fiber_def :reader, max: 2
every_ms 10, :tick

def reader(limit)
  i = 0
  while i < limit
    Fiber.yield i
    i += 1
  end
  limit
end

def tick(out)
  Reader.start(1, 3)
  0
end
