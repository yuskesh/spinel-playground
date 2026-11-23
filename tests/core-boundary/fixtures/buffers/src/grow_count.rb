# A buffer kernel fixture for decision 0007 task 3.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# The count parameter is an ordinary local and may be assigned. What it may NOT
# do is move the bound: that is a fact about the descriptor, captured from the
# parameter as it arrived.
#
# Measured before the two were separated: this returned success, wrote 77 one
# element past the count, and left the result at 0.

def grow_count(dst, n_dst)
  n_dst = n_dst + 1
  dst[n_dst - 1] = 77
  0
end
