class C
  def step
    Fiber.yield 1
    2
  end

  def run
    step
  end
end

class D < C
  include Comparable
end
