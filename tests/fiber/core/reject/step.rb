require "spinel/core"
state :out, :i32, 1
fiber_def :reader, max: 2
every_ms 10, :tick
def reader(n)
  i = 0
  while i < n
    Fiber.yield i if i.even?
    i += 1
  end
  0
end
def tick(out)
  out[0] = Reader.resume(0, 0)
  0
end
