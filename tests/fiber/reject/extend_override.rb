class C
  def step
    Fiber.yield 1
    2
  end

  def run
    step
  end
end

module Quiet
end
d = C.new
d.extend(Quiet)
