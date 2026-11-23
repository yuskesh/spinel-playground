# tests/core-bitwise/refuse/self_w64.rb -- decision 0042 stage 4: an intrinsic
# called with a receiver.
require_relative "spinel/freestanding"

freestanding_def :f, params: [:i64, :i64], returns: :i64
def f(a, b)
  self.core_w64_add(a, b)
end
