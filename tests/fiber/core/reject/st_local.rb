require "spinel/core"
state :out, :i32, 1
fiber_def :reader, max: 1
every_ms 10, :tick

def reader(n)
  st = n
  Fiber.yield st
end

def tick(out)
  Reader.start(0, 3) unless Reader.alive?(0)
  out[0] = Reader.resume(0, 0)
  0
end
