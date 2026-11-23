# A buffer kernel fixture for decision 0007 task 3.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# The other direction: the local is set BELOW the descriptor count, and an
# index the descriptor admits still succeeds. A bound taken from the local
# would refuse this one.

def shrink_count(dst, n_dst)
  n_dst = 0
  dst[0] = 7
  0
end
