# Misuse: free past the end of a pool of 2 slots. It is BOUNDS (decision 0041 stage 3,
# option 2).
require "spinel/core"
state :out, :i32, 1
pool_def :node, max: 2
every_ms 10, :tick

def tick(out)
  Node.free(2)
  out[0] = 1
  0
end
