f = Fiber.new do |a, b|
  a
end
f.resume(1)
