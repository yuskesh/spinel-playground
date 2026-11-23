require_relative "spinel/freestanding"
freestanding_def :add64, params: [:i64, :i64], returns: :i64
def add64(a, b)
  a + b
end
