def calculate(a, b)
  a.abs
end

puts calculate(5, 0)
puts calculate(0, 0)
puts calculate(9223372036854775807, 0)
puts calculate(-9223372036854775807, 0)
