# A buffer kernel fixture for decision 0007 task 3.
#
# One entry per file, plus any helpers it calls, and no caller anywhere: the
# contract declares each buffer element type, mode and count parameter, and the
# checker derives the rest of the closure from those facts.

# One `in` buffer and one `inout`, each with its own count. Any overlap
# involving the `inout` is refused at entry, including two names for the same
# storage; two read-only buffers may overlap.

def copy_u8(dst, n_dst, src, n_src)
  i = 0
  while i < n_dst
    if i < n_src
      dst[i] = src[i]
    else
      dst[i] = 0
    end
    i = i + 1
  end
  n_dst
end
