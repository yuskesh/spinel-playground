# A buffer kernel fixture for decision 0007 task 3.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# Writes every element and then stores at an index the caller chose. When that
# index is out of range the failure happens after execution has begun: the
# prefix stays, the failing store does not execute, and the result is not
# published.

def write_then_oob(dst, n_dst, i)
  j = 0
  while j < n_dst
    dst[j] = 5
    j = j + 1
  end
  dst[i] = 9
  n_dst
end
