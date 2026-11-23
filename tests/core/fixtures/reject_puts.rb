require_relative "spinel/freestanding"
freestanding_def :p, params: [:i32], returns: :i32
def p(n)
  puts n
  n
end
