def emit(x)
  Fiber.yield x * 10
  nil
end

def pair(a)
  emit(a)
  emit(a + 1)
end

f = Fiber.new do |start|
  puts "start #{start}"
  i = 0
  while i < 2
    got = Fiber.yield i
    puts "got #{got}"
    i += 1
  end
  pair(5)
  3.times do |k|
    Fiber.yield 100 + k
  end
  :done
end

p f.resume(:s)
p f.resume(:a)
p f.resume(:b)
p f.resume
p f.resume
p f.resume
p f.resume
p f.resume
p f.alive?
begin
  f.resume
rescue FiberError => e
  puts "FiberError: #{e.message}"
end
