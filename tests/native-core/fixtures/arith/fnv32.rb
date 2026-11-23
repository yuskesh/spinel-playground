# Decision 0042 stage 4 (tests/native-core/arith.sh): FNV-1a 32 of "a"
# (0xe40c292c) and "foobar" (0xbf9cf968), from the offset basis 0x811c9dc5.
def fnv32_step(h, b)
  core_w32_mul(h ^ b, 16777619)
end

def calculate(n, b0, b1, b2, b3, b4, b5)
  h = core_u32(0x811c9dc5)
  h = n > 0 ? fnv32_step(h, b0) : h
  h = n > 1 ? fnv32_step(h, b1) : h
  h = n > 2 ? fnv32_step(h, b2) : h
  h = n > 3 ? fnv32_step(h, b3) : h
  h = n > 4 ? fnv32_step(h, b4) : h
  h = n > 5 ? fnv32_step(h, b5) : h
  h
end

puts calculate(1, 97, 0, 0, 0, 0, 0)
puts calculate(6, 102, 111, 111, 98, 97, 114)
