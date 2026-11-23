def calculate(a, b)
  (a & 0xf0) / b
end

puts calculate(0xa7, 16)
