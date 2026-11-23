# A buffer kernel fixture for decision 0007 task 3.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# `n += 1` is the same statement written differently, and means the same here.

def grow_count_op(dst, n_dst)
  n_dst += 1
  dst[n_dst - 1] = 77
  0
end
