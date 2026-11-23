def gen(name, n)
  i = 0
  while i < n
    Fiber.yield "#{name}#{i}"
    i += 1
  end
  "#{name} done"
end

def ask(q)
  ans = Fiber.yield q
  "#{q}=#{ans}"
end

a = Fiber.new { gen("a", 2) }
b = Fiber.new { gen("b", 3) }
4.times do
  puts a.resume if a.alive?
  puts b.resume if b.alive?
end

c = Fiber.new do
  r1 = ask("x")
  r2 = ask("y")
  "#{r1},#{r2}"
end
p c.resume
p c.resume(1)
p c.resume(2)
p c.alive?

d = Fiber.new do |x|
  next :neg if x < 0
  Fiber.yield x
  :pos
end
p d.resume(-1)
p d.alive?
