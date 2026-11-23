# Decision 0022 §3: a count the body reads, at the 32-bit body width. The
# buffer's elements are never accessed, so a descriptor the wrapper admits at
# the top of the address space touches no memory.
def len_u8(src, n_src)
  n_src
end
