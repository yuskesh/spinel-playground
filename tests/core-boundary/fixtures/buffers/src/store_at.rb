# A buffer kernel fixture for decision 0007 task 3.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# The index of a STORE comes from the caller, so both ends of
# `0 <= index < count` are exercised on the writing side and not only on the
# reading one.

def store_at(dst, n_dst, i, v)
  dst[i] = v
  n_dst
end
