require_relative "spinel/freestanding"
# uses NO extern: an extern-bearing profile must not change what this compiles to
freestanding_def :add, params: [:i32, :i32], returns: :i32
def add(a, b)
  a + b
end
