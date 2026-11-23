class C
  def step
    Fiber.yield 1
    2
  end

  def run
    step
  end
end

module N
  def step
    9
  end
end

class D < C
  include N
end
