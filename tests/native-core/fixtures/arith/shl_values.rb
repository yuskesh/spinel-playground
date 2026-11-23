def calculate(a, n)
  a << n
end

puts calculate(1, 62)
puts calculate(-1, 63)
puts calculate(5, -1)
puts calculate(-5, -64)
puts calculate(0, 64)
puts calculate(5, -9223372036854775808)
