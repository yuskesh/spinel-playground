require "spinel/core"
state :out, :i32, 1
enum_def :evens, max: 1
every_ms 10, :tick

def evens(y, n)
  Fiber.yield n
end

def tick(out)
  Evens.start(0, 3) unless Evens.alive?(0)
  out[0] = Evens.next(0)
  0
end
