require_relative "spinel/freestanding"
freestanding_def :s, params: [:i32], returns: :i32
def s(n)
  "x" * n
  n
end
