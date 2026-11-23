require_relative "spinel/freestanding"
freestanding_def :imin, params: [:i32, :i32], returns: :i32
def imin(a, b)
  a < b ? a : b
end
