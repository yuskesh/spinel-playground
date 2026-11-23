# The receiver is a Gen on one path and a Tap on the other, so the call to
# the yielding method cannot be resolved to one class.
class Gen
  def step
    Fiber.yield 1
  end
end

class Tap
  def step
    Fiber.yield 2
  end
end

o = ARGV.empty? ? Gen.new : Tap.new
f = Fiber.new { o.step }
p f.resume
