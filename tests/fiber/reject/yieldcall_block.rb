def tick
  Fiber.yield 1
end
f = Fiber.new { [1].map { |v| tick } }
f.resume
