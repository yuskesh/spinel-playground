require "spinel/core"
state :out, :i32, 1
fiber_def :reader, max: 2
every_ms 10, :tick
def reader(n)
  Reader.start(1, n)
  Fiber.yield n
  0
end
def tick(out)
  0
end
