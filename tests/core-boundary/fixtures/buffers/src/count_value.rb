# A buffer kernel fixture for decision 0007 task 3.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# Returns the count and never touches the buffer.
#
# That is the point: a count of 2^32 truncated to 32 bits reads as zero, and
# this is the one shape that can tell the two apart without an access. A kernel
# that stored would need the storage to exist, and four gibibytes of it.

def count_value(dst, n_dst)
  n_dst
end
