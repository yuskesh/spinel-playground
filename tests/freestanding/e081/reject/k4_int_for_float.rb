require_relative "spinel/freestanding"
freestanding_def :go, params: [:i32], returns: :f64
def go(n)
  sense_scale(n, 2.0)
end
