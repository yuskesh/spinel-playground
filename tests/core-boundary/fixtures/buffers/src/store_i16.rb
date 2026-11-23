# A buffer kernel fixture for decision 0018.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# Stores range-check against the DECLARED element type before writing. i16 is
# signed, so -32768 and 32767 fit and -32769 and 32768 do not.

def store_i16(dst, n_dst, v)
  if n_dst > 0
    dst[0] = v
  else
    0
  end
  n_dst
end
