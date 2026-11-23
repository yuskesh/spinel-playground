require_relative "spinel/freestanding"
freestanding_def :mk, params: [:i32], returns: :i32
def mk(n)
  a = [n, n]
  a[0]
end
