# A buffer kernel fixture for decision 0007 task 3.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# An i64 input buffer with an i64 result: the one shape in which an `invoke`
# whose result id equals a participant id differs from that participant in
# NOTHING but the id. With a u8 input the element-type check refuses it first
# and the identity rule is never reached.

def sum_i64(src, n_src)
  i = 0
  total = 0
  while i < n_src
    total = total + src[i]
    i = i + 1
  end
  total
end
