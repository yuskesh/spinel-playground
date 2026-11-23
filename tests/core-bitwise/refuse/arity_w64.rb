# tests/core-bitwise/refuse/arity_w64.rb -- decision 0042 stage 4: an
# intrinsic called with the wrong number of arguments.
require_relative "spinel/freestanding"

freestanding_def :f, params: [:i64, :i64], returns: :i64
def f(a, b)
  core_w64_add(a)
end
