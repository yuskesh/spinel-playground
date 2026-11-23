def calculate(r)
  ((r >> 4) & 0xf) * 100 + (r & 0xf)
end

puts calculate(0xa7)
