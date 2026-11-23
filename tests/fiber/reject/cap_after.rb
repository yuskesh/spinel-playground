n = 1
e = Enumerator.new { |y| y << n }
n = 2
p e.next
