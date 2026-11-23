# One Fiber.new site run several times in one activation makes independent
# fibers: in a block, in a while loop, and in a lambda called twice.
fs = []
3.times do |k|
  fs << Fiber.new do
    j = k * 100
    while true
      Fiber.yield j
      j += 1
    end
  end
end
fs[0].resume
fs[0].resume
p fs[0].resume
p fs[1].resume
p fs[2].resume
p fs[1].resume

gs = []
i = 0
while i < 2
  gs << Fiber.new do
    c = 0
    loop do
      c += 1
      Fiber.yield c
    end
  end
  i += 1
end
gs[0].resume
p gs[0].resume
p gs[1].resume

mk = lambda do |base|
  Fiber.new do
    Fiber.yield base
    base + 1
  end
end
a = mk.call(10)
b = mk.call(20)
p a.resume
p b.resume
p a.resume
p b.resume
p a.alive?

# a begin whose rescue retries runs the site again in the same activation
def retried
  fs = []
  n = 0
  begin
    f = Fiber.new do
      i = 0
      while true
        Fiber.yield i
        i += 1
      end
    end
    fs << f
    n += 1
    raise "again" if n < 2
  rescue
    retry
  end
  fs
end
r1, r2 = retried
p r1.resume, r1.resume, r2.resume
