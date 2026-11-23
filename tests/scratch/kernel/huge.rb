# Decision 0041 stage 2, the review: 2^60 elements of 8 bytes is past
# 2^63; the worst total saturates and is refused, not wrapped to a negative.
def tick(out)
  a = Core::Buffer.i64(1152921504606846976, 0)
  out[0] = a.size
  0
end
