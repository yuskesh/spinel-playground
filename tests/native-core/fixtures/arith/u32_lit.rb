# Decision 0042 stage 4 (tests/native-core/arith.sh): `core_u32(0xdeadbeef)`,
# a constant.
def calculate(a)
  core_u32(0xdeadbeef) ^ a
end

puts calculate(0)
