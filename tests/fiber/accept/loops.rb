def countdown(n)
  return :liftoff if n == 0
  Fiber.yield n
  countdown(n - 1)
end

f = Fiber.new do
  r = countdown(3)
  puts "countdown gave #{r}"
  k = 0
  loop do
    k += 1
    next if k == 2
    break if k > 3
    Fiber.yield k * 10
  end
  1.upto(2) { |u| Fiber.yield u + 100 }
  (5...7).each { |e| Fiber.yield e }
  [:x, :y].each do |s|
    if s == :x
      Fiber.yield "is x"
    elsif s == :z
      puts "never"
    else
      Fiber.yield "not x"
    end
  end
  n = 0
  until n == 2
    unless n == 1
      Fiber.yield "n=#{n}"
    end
    n += 1
  end
  :end
end

while f.alive?
  p f.resume
end
