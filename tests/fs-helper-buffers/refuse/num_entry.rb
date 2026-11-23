# A buffer passed where a callee that is an entry too takes a number.
require_relative "spinel/freestanding"
freestanding_def :g, params: [[:i32_buf, :inout], :len, :i32], returns: :i32
def g(b, n, x)
  n
end
freestanding_def :k, params: [[:i32_buf, :inout], :len], returns: :i32
def k(out, n)
  g(out, n, out)
end
