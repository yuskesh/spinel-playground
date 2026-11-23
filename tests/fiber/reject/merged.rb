f = Fiber.new do
  [1, 2].each { |v| y = v }
  y = 0
  Fiber.yield y
end
f.resume
