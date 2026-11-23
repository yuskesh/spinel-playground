# An :in buffer lent to a callee that is an entry declaring it :inout.
require_relative "spinel/freestanding"
freestanding_def :g, params: [[:i32_buf, :inout], :len], returns: :i32
def g(b, n)
  b[0] = 1
  n
end
freestanding_def :k, params: [[:i32_buf, :in], :len], returns: :i32
def k(src, n)
  g(src, n)
end
