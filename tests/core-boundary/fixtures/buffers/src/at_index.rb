# A buffer kernel fixture for decision 0007 task 3.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# The index comes from a scalar the caller supplies, so it exercises both ends
# of `0 <= index < count` -- including the arithmetic that computes it.

def at_index(src, n_src, i)
  src[i + 0]
end
