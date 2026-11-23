def counter(limit)
  Fiber.new do
    i = 0
    while i < limit
      Fiber.yield i
      i += 1
    end
    :counted
  end
end

outer = Fiber.new do
  inner = Fiber.new do |x|
    Fiber.yield x * 2
    x * 3
  end
  a = inner.resume(5)
  Fiber.yield a
  b = inner.resume
  Fiber.yield b
  c = counter(2)
  Fiber.yield c.resume
  Fiber.yield c.resume
  c.resume
end

p outer.resume
p outer.resume
p outer.resume
p outer.resume
p outer.resume
p outer.alive?
