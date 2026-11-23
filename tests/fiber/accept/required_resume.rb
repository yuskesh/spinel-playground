require_relative "tape"
f = Fiber.new { Fiber.yield 1; 2 }
p f.resume
p Tape.new.resume
p f.resume
