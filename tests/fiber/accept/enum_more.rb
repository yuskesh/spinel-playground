# Enumerators in a method and in a class, drained by loop inside another
# enumerator and inside a fiber, an exception through next, and the ends.
def countdown(n)
  Enumerator.new do |y|
    k = n
    while k > 0
      y << k
      k -= 1
    end
    :liftoff
  end
end
p countdown(3).to_a

class Squares
  def initialize(limit)
    @limit = limit
  end

  def sq(x)
    x * x
  end

  def enum
    Enumerator.new do |y|
      i = 1
      while i <= @limit
        y.yield sq(i)
        i += 1
      end
    end
  end
end
e = Squares.new(4).enum
p e.next
p e.next
p e.to_a
p e.next

evens = Enumerator.new do |y|
  src = countdown(6)
  loop do
    v = src.next
    y << v if v.even?
  end
end
p evens.to_a

f = Fiber.new do
  en = countdown(2)
  loop do
    Fiber.yield en.next
  end
  :drained
end
p f.resume
p f.resume
p f.resume
p f.alive?

bad = Enumerator.new do |y|
  y << 1
  raise ArgumentError, "boom"
end
p bad.next
begin
  bad.next
rescue ArgumentError => ex
  puts "raised: #{ex.message}"
end

one = Enumerator.new { |y| y << :only }
p one.next
begin
  one.peek
rescue StopIteration
  puts "peek: end"
end
begin
  one.next
rescue StopIteration
  puts "next: end"
end
none = Enumerator.new { |y| }
p none.first
p none.to_a
