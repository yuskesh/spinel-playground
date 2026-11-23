require_relative "spinel/freestanding"
freestanding_def :add32, params: [:i32, :i32], returns: :i32
def add32(a, b)
  a + b
end
