# A helper returns its lent buffer.
require_relative "spinel/freestanding"
def back(b)
  b
end
freestanding_def :k, params: [[:i32_buf, :inout], :len], returns: :i32
def k(out, n)
  back(out)
  n
end
