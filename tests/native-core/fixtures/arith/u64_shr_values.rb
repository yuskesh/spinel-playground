# Decision 0042 stage 4 (tests/native-core/arith.sh): five rows of
# `core_u64_shr(a, b)`.
def calculate(a, b)
  core_u64_shr(a, b)
end

puts calculate(-1, 1)
puts calculate(-1, 63)
puts calculate(-9223372036854775808, 63)
puts calculate(-1, 0)
puts calculate(12345, 4)
