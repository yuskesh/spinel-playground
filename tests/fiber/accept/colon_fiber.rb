f = ::Fiber.new do |x|
  ::Fiber.yield x + 1
  x + 2
end
p f.resume(4)
p f.resume
