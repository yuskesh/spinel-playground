class C
  def step
    Fiber.yield 1
    2
  end

  def run
    step
  end
end

module Outer
  class D < C
    def step
      3
    end
  end
end
