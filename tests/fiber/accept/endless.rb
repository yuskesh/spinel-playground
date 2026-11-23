# A yielding method written as an endless def: its factory goes after the
# def, which ends where the rewritten Fiber.yield ends.
def t = Fiber.yield(1)
f = Fiber.new { t; 2 }
p f.resume
p f.resume
