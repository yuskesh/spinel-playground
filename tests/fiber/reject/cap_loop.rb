fs = []
i = 0
while i < 2
  fs << Fiber.new { Fiber.yield i }
  i += 1
end
