# A helper stores into a parameter lent from an :in buffer.
require_relative "spinel/freestanding"
def clear(b, i)
  b[i] = 0
  0
end
freestanding_def :k, params: [[:i32_buf, :in], :len], returns: :i32
def k(src, n)
  clear(src, 0)
end
