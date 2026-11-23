# Decision 0042 stage 4 (tests/native-core/arith.sh): a `core_u32_shr` count
# outside 0..31 fails.
def calculate(a, b)
  core_u32_shr(a, b)
end

puts calculate(-1, 32)
