# A buffer kernel fixture for decision 0007 task 3.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# An i64 `inout` buffer whose index the caller chooses, so a failed invocation
# leaves a POISONED i64 buffer -- the one thing that can then be offered back
# as an i64 result.

def store_at_i64(dst, n_dst, i, v)
  dst[i] = v
  n_dst
end
