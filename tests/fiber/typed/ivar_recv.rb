# The receiver is an instance variable: another method may change it while
# the fiber is suspended, so it must be copied to a local first.
class Gen
  def step
    Fiber.yield 1
  end
end

class Box
  def initialize
    @g = Gen.new
  end

  def run
    f = Fiber.new { @g.step }
    f.resume
  end
end
p Box.new.run
