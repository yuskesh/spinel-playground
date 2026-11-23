f = Fiber.new do
  Fiber.yield 1
end
f.raise ArgumentError
