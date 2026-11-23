# tests/core-bitwise/refuse/block_w64.rb -- decision 0042 stage 4: an
# intrinsic called with a block.
require_relative "spinel/freestanding"

freestanding_def :f, params: [:i64, :i64], returns: :i64
def f(a, b)
  core_w64_add(a, b) { 1 }
end
