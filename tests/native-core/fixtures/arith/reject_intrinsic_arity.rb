# Decision 0042 stage 4 (tests/native-core/arith.sh): refused, an
# intrinsic called with the wrong number of arguments.
def calculate(a, b)
  core_w64_add(a)
end

puts calculate(1, 2)
