# A helper stores its lent buffer into a local.
require_relative "spinel/freestanding"
def keep(b, i)
  x = b
  i
end
freestanding_def :k, params: [[:i32_buf, :inout], :len], returns: :i32
def k(out, n)
  keep(out, 0)
end
