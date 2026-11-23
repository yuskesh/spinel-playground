require_relative "spinel/freestanding"

freestanding_def :bool_and, params: [:i64, :i64], returns: :i64
def bool_and(a, b)
  ((a < b) & (b < a)) ? 1 : 0
end
