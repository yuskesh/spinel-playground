def calculate(a, n)
  a >> n
end

puts calculate(-48, 4)
puts calculate(-9223372036854775808, 63)
puts calculate(-5, 64)
puts calculate(5, 9223372036854775807)
puts calculate(5, -1)
puts calculate(-1, -63)
