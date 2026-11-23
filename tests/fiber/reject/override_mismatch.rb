class Base
  def step
    Fiber.yield 1
  end
end

class Quiet < Base
  def step
    2
  end
end
