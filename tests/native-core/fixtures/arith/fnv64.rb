# Decision 0042 stage 4 (tests/native-core/arith.sh): FNV-1a 64 of "a"
# (0xaf63dc4c8601ec8c) and "foobar" (0x85944171f73967e8), from the offset
# basis 0xcbf29ce484222325.
def fnv64_step(h, b)
  core_w64_mul(h ^ b, 1099511628211)
end

def calculate(n, b0, b1, b2, b3, b4, b5)
  h = -3750763034362895579
  h = n > 0 ? fnv64_step(h, b0) : h
  h = n > 1 ? fnv64_step(h, b1) : h
  h = n > 2 ? fnv64_step(h, b2) : h
  h = n > 3 ? fnv64_step(h, b3) : h
  h = n > 4 ? fnv64_step(h, b4) : h
  h = n > 5 ? fnv64_step(h, b5) : h
  h
end

puts calculate(1, 97, 0, 0, 0, 0, 0)
puts calculate(6, 102, 111, 111, 98, 97, 114)
