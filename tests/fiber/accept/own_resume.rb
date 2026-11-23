class Tape
  def resume
    "tape"
  end
end
f = Fiber.new do
  Fiber.yield 1
  2
end
p f.resume
p Tape.new.resume
p f.resume
