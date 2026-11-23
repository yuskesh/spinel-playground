# A buffer kernel fixture for decision 0018.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# Loads zero-extend u16, so 65535 is 65535 and not -1.

def sum_u16(src, n_src)
  i = 0
  total = 0
  while i < n_src
    total = total + src[i]
    i = i + 1
  end
  total
end
