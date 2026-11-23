def ask(q)
  Fiber.yield q
end

f = Fiber.new do |base|
  total = base + Fiber.yield(:first)
  puts "total #{total}"
  puts "sum #{Fiber.yield(:a) + Fiber.yield(:b)}"
  x = [1, ask(:q), 3]
  p x
  if Fiber.yield(:cond)
    puts "yes"
  end
  n = 0
  while Fiber.yield(n) != :stop
    n += 1
  end
  n
end

p f.resume(10)
p f.resume(5)
p f.resume(1)
p f.resume(2)
p f.resume(:two)
p f.resume(true)
p f.resume(:go)
p f.resume(:stop)
