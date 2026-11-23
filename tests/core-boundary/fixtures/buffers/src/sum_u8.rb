# A buffer kernel fixture for decision 0007 task 3.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# Loads zero-extend u8 into i64, so 255 is 255 and never -1.

def sum_u8(src, n_src)
  i = 0
  total = 0
  while i < n_src
    total = total + src[i]
    i = i + 1
  end
  total
end
