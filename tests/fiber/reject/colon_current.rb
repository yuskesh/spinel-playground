f = ::Fiber.new { ::Fiber.current }
f.resume
