def calculate(a)
  (a | 0x80) & ~0x01
end

puts calculate(0x41)
