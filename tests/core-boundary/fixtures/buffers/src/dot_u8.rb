# A buffer kernel fixture for decision 0007 task 3.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# Two read-only buffers, which MAY overlap -- including two arguments naming
# identical storage. Only an overlap involving an `inout` buffer is refused.

def dot_u8(a, n_a, b, n_b)
  i = 0
  total = 0
  while i < n_a
    if i < n_b
      total = total + a[i] * b[i]
    else
      total = total
    end
    i = i + 1
  end
  total
end
