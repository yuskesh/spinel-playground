# A helper stores its lent buffer into an element.
require_relative "spinel/freestanding"
def nest(b, i)
  b[i] = b
  0
end
freestanding_def :k, params: [[:i32_buf, :inout], :len], returns: :i32
def k(out, n)
  nest(out, 0)
end
