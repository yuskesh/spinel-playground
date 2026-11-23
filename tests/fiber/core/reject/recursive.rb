require "spinel/core"
state :out, :i32, 1
fiber_def :reader, max: 2
every_ms 10, :tick
def reader(n)
  Fiber.yield n
  reader(n - 1)
end
def tick(out)
  0
end
