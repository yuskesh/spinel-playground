# A buffer kernel fixture for decision 0018.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# Loads sign-extend i16 into i64, so -32768 is -32768 and not 32768.

def sum_i16(src, n_src)
  i = 0
  total = 0
  while i < n_src
    total = total + src[i]
    i = i + 1
  end
  total
end
