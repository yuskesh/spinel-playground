# A buffer kernel fixture for decision 0007 task 3.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# An i64 element holds the whole signed domain, INT64_MIN included: stored,
# loaded back and returned through the result pointer.

def roundtrip_i64(dst, n_dst, v)
  if n_dst > 0
    dst[0] = v
  else
    0
  end
  dst[0]
end
