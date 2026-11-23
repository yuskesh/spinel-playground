require_relative "spinel/freestanding"

freestanding_def :float_shr, params: [:f64], returns: :f64
def float_shr(x)
  x >> 1
end
