require_relative "spinel/freestanding"

freestanding_def :float_and, params: [:f64], returns: :f64
def float_and(x)
  x & 1
end
