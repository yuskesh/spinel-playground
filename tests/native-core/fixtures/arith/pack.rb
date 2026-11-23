def calculate(a, b)
  (a << 8) | b
end

puts calculate(0x12, 0x34)
