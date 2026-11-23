e = Enumerator.new do |y|
  Fiber.yield 1
end
