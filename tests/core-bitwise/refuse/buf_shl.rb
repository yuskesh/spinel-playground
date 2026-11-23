require_relative "spinel/freestanding"

# `<<` on a buffer: an Array append, not a shift.
freestanding_def :buf_shl, params: [[:i64_buf, :inout], :len], returns: :i64
def buf_shl(b, n)
  b << 1
  n
end
