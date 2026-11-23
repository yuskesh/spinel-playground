class Reg
  def initialize(v, sink)
    @v = v
    sink << Fiber.new { Fiber.yield(@v + 1); @v + 2 }
  end
end
sink = []
Reg.new(10, sink)
f = sink[0]
p f.resume
p f.resume
p f.alive?
