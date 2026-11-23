# A buffer kernel fixture for decision 0007 task 3.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# Writes every element and then makes one more store that may be out of range.
# Entry validation happens before any write, so an entry failure leaves the
# buffer untouched; this failure happens after execution has begun, and the
# already-written prefix stays. The failing store itself does not execute.

def partial_store(dst, n_dst, v)
  i = 0
  while i < n_dst
    dst[i] = 1
    i = i + 1
  end
  if n_dst > 0
    dst[0] = v
  else
    0
  end
  n_dst
end
