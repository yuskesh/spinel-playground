# A refusal fixture for decision 0007 task 3. Not a case in the descriptor
# table: it exists to be rejected, and buffers.sh declares the diagnostic it
# must be rejected with.

# The buffer parameter names an address the caller owns. Rebinding the name
# makes every later access say something the call did not.

def buffer_rebound(src, n_src)
  src = 0
  n_src
end
