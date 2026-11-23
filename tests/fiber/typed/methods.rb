# Yielding instance methods reached through a receiver the analysis types
# (decision 0035): an implicit and a self call, a method found in the
# superclass, an override that yields too, instance variables, a return
# value, and the original method called outside any fiber.
class Counter
  def initialize(start)
    @n = start
  end

  def tick(step)
    @n += step
    Fiber.yield @n
    @n
  end

  def twice(step)
    a = tick(step)
    b = self.tick(step)
    a + b
  end
end

class Loud < Counter
  def tick(step)
    @n += step * 100
    Fiber.yield(-@n)
    @n
  end
end

c = Counter.new(0)
f = Fiber.new do
  r = c.twice(1)
  Fiber.yield r
  :done
end
p f.resume
p f.resume
p f.resume
p f.resume

l = Loud.new(0)
g = Fiber.new do
  l.twice(1)
end
p g.resume
p g.resume
p g.resume
p g.alive?

begin
  c.tick(5)
rescue FiberError
  puts "FiberError"
end
