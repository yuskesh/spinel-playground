# A refusal fixture for decision 0007 task 3. Not a case in the descriptor
# table: it exists to be rejected, and buffers.sh declares the diagnostic it
# must be rejected with.

# A store into a buffer the contract declares `in`. The mode is the whole
# promise: a caller that passed read-only storage has been told nothing will be
# written to it.

def readonly_write(src, n_src)
  src[0] = 1
  n_src
end
