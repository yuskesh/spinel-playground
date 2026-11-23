# tests/core-bitwise/req/main.rb -- decision 0042 stage 4: the root calls a
# helper from a required file, and only that file spells an intrinsic. The
# prelude is picked from every file the analysis reads, so this compiles.
require_relative "spinel/freestanding"
require_relative "helper"

freestanding_def :f, params: [:i32, :i32], returns: :i32
def f(a, b)
  helper(a, b)
end
