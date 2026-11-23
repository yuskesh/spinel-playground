f = Fiber.new do
  x = true && Fiber.yield(1)
  x
end
f.resume
