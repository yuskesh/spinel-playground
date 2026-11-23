def emit(x)
  Fiber.yield x
end
f = Fiber.new { send(:emit, 1) }
f.resume
