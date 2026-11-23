# Misuse: free of a slot never handed out. It is BOUNDS (decision 0041
# stage 3, option 2).
require "spinel/core"
state :out, :i32, 1
pool_def :node, max: 2
every_ms 10, :tick

def tick(out)
  Node.free(1)
  out[0] = 1
  0
end
