def calculate(a, b)
  a ** b
end

puts calculate(0, 0)
puts calculate(-2, 63)
puts calculate(3, 39)
puts calculate(-3, 39)
puts calculate(-1, 9223372036854775807)
puts calculate(1, 9223372036854775807)
puts calculate(0, 64)
