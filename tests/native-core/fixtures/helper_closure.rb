def lower(a, b)
  a < b ? a : b
end

def pick3(a, b, c)
  lower(lower(a, b), c)
end

puts pick3(7, 3, 5)
