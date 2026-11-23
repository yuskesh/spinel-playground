f = Fiber.new do
  [1, 2].map { |v| Fiber.yield v }
end
f.resume
