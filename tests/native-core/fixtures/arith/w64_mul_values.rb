# Decision 0042 stage 4 (tests/native-core/arith.sh): five rows of
# `core_w64_mul(a, b)`.
def calculate(a, b)
  core_w64_mul(a, b)
end

puts calculate(9223372036854775807, 9223372036854775807)
puts calculate(-9223372036854775808, -1)
puts calculate(4294967296, 4294967296)
puts calculate(-3, 7)
puts calculate(1099511628211, -3750763034362895579)
