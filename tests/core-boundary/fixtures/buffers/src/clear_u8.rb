# A buffer kernel fixture for decision 0007 task 3.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# A loop the optimiser may turn into a memset. Version 1 keeps the object's
# undefined set empty, so whether it does is something to inspect rather than
# assume.

def clear_u8(dst, n_dst)
  i = 0
  while i < n_dst
    dst[i] = 0
    i = i + 1
  end
  n_dst
end
