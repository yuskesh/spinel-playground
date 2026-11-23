def calculate(a, b)
  ((a < b) & (b < a)) ? 1 : 0
end

puts calculate(1, 2)
