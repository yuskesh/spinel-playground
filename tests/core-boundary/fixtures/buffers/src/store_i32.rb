# A buffer kernel fixture for decision 0007 task 3.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# Stores range-check against the DECLARED element type before writing. i32 is
# signed, so 2147483647 fits and 2147483648 does not.

def store_i32(dst, n_dst, v)
  if n_dst > 0
    dst[0] = v
  else
    0
  end
  n_dst
end
