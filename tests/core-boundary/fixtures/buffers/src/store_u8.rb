# A buffer kernel fixture for decision 0007 task 3.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# Stores range-check before writing: there is no implicit truncation, and an
# out-of-range store is ARITHMETIC without executing that store. A caller
# wanting a masked value computes the mask explicitly.

def store_u8(dst, n_dst, v)
  if n_dst > 0
    dst[0] = v
  else
    0
  end
  n_dst
end
