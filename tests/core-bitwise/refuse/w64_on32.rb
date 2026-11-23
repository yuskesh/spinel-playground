# tests/core-bitwise/refuse/w64_on32.rb -- decision 0042 stage 4: a 64-bit
# form on the wasm32 profile's 32-bit body, refused as int64 is (decision
# 0019's revision). run.sh compiles it for the wasm32 profile.
require_relative "spinel/freestanding"

freestanding_def :f, params: [:i32, :i32], returns: :i32
def f(a, b)
  core_w64_add(a, b)
end
