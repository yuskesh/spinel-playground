def calculate(a)
  a & 0xffff_ffff
end

puts calculate(-1)
