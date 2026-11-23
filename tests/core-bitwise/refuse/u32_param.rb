# tests/core-bitwise/refuse/u32_param.rb -- decision 0042 stage 4: `core_u32`
# of a parameter: it takes an Integer literal only.
require_relative "spinel/freestanding"

freestanding_def :f, params: [:i64], returns: :i64
def f(a)
  core_u32(a)
end
