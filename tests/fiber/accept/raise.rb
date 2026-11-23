f = Fiber.new do
  Fiber.yield 1
  raise ArgumentError, "boom"
end
p f.resume
begin
  f.resume
rescue ArgumentError => e
  puts "caught #{e.message}"
end
p f.alive?
begin
  Fiber.yield 3
rescue FiberError => e
  puts "root: #{e.message}"
end
