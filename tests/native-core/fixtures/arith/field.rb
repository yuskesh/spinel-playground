def calculate(a)
  (a & 0xf0) / 16 * 100 + (a & 0xf)
end

puts calculate(0xa7)
