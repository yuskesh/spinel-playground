# Decision 0042 stage 4 (tests/native-core/arith.sh): refused, an unused
# top-level definition of an intrinsic's name: the prelude defines it for the
# hosted half and the analysis.
def core_w64_add(a, b)
  a + b
end

def calculate(a, b)
  a - b
end

puts calculate(1, 2)
