# Decision 0042 stage 4 (tests/native-core/arith.sh): five rows of
# `core_u64_ge(a, b) ? 1 : 0`.
def calculate(a, b)
  core_u64_ge(a, b) ? 1 : 0
end

puts calculate(0, -1)
puts calculate(-1, 0)
puts calculate(5, 5)
puts calculate(-9223372036854775808, 9223372036854775807)
puts calculate(9223372036854775807, -9223372036854775808)
