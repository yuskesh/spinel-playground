# Decision 0042 stage 4 (tests/native-core/arith.sh): five rows of
# `core_w64_add(a, b)`.
def calculate(a, b)
  core_w64_add(a, b)
end

puts calculate(9223372036854775807, 1)
puts calculate(-9223372036854775808, -1)
puts calculate(-1, -1)
puts calculate(123, 456)
puts calculate(9223372036854775807, 9223372036854775807)
