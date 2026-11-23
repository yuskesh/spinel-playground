# Decision 0042 stage 4 (tests/native-core/arith.sh): five rows of
# `core_w64_shl(a, b)`.
def calculate(a, b)
  core_w64_shl(a, b)
end

puts calculate(1, 63)
puts calculate(1, 64)
puts calculate(3, -1)
puts calculate(-9223372036854775808, -1000)
puts calculate(-5, -9223372036854775808)
