module Steps
  def self.one
    1
  end

  def step
    Fiber.yield 1
  end
end
