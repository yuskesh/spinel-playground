require_relative "helper"
f = Fiber.new do
  Fiber.yield helper(1)
  helper(10)
end
p f.resume
p f.resume
