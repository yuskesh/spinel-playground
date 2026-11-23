# Decision 0042 stage 4 (tests/native-core/arith.sh): refused, `core_u32`
# of a literal past 0..4294967295.
def calculate(a)
  core_u32(4294967296) ^ a
end

puts calculate(1)
