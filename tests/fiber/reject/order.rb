def side
  puts "side"
  1
end
f = Fiber.new do
  x = side + Fiber.yield(2)
  x
end
f.resume
