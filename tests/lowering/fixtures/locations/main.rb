require_relative "spinel/freestanding"
require_relative "helper"
freestanding_def :f, params: [:i32], returns: :i32
def f(x)
  g(x) + 1
end
