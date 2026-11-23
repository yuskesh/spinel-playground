# A buffer kernel fixture for decision 0007 task 3.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# TWO `inout` buffers. The overlap rule is about any buffer that is written, so
# it has to hold between two of them and not only between a written one and a
# read-only one -- which is the only pairing copy_u8 could exercise.

def merge_into(dst, n_dst, other, n_other)
  i = 0
  while i < n_dst
    if i < n_other
      dst[i] = other[i]
    else
      dst[i] = 0
    end
    i = i + 1
  end
  n_dst
end
