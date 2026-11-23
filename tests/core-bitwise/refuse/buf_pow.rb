require_relative "spinel/freestanding"

# `**` on a buffer: not a power of two Integers.
freestanding_def :buf_pow, params: [[:i64_buf, :inout], :len], returns: :i64
def buf_pow(b, n)
  b ** 2
  n
end
