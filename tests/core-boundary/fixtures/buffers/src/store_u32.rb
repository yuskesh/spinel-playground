# A buffer kernel fixture for decision 0007 task 3.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# The same check against an unsigned element: 4294967295 fits and -1 does not.
# A caller wanting the low 32 bits of a negative value computes the mask.

def store_u32(dst, n_dst, v)
  if n_dst > 0
    dst[0] = v
  else
    0
  end
  n_dst
end
