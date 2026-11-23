# Misuse: a double free. It is BOUNDS (decision 0041 stage 3, option 2).
require "spinel/core"
state :out, :i32, 1
pool_def :node, max: 2
every_ms 10, :tick

def tick(out)
  s = Node.alloc
  Node.free(s)
  Node.free(s)
  out[0] = s
  0
end
