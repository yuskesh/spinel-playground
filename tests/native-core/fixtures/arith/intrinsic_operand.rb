# Decision 0042 stage 4 (tests/native-core/arith.sh): an operand outside the
# i32 range fails.
def calculate(a, b)
  core_w32_add(a, b)
end

puts calculate(2147483648, 0)
