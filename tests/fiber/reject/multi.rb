f = Fiber.new { Fiber.yield 1, 2 }
f.resume
