# Enumerator.new with external and internal iteration.
fib = Enumerator.new do |y|
  a = 0
  b = 1
  loop do
    y << a
    a, b = b, a + b
  end
end
p fib.take(8)
p fib.first
p fib.next
p fib.next
p fib.peek
p fib.next
fib.rewind
p fib.next

e = Enumerator.new do |y|
  y.yield 1
  y << 2
  3.times { |i| y << (10 + i) }
  [:a, :b].each { |s| y.yield s }
  :done
end
p e.to_a
p e.map { |x| x.to_s }
p e.include?(11)
p e.size
e.each_with_index { |x, i| puts "#{i} #{x}" }
loop do
  puts e.next
end
puts "after"
begin
  e.next
rescue StopIteration => ex
  puts "stop: #{ex.message}"
end
p 5.next
