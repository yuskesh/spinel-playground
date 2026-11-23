require_relative "spinel/freestanding"
freestanding_def :add, params: [:i32, :i32], returns: :i32
def add(a, b)
  a + b
end
