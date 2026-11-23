# Refused: one pool used from two contexts (decision 0041 stage 3, one owning context).
require "spinel/core"
state :out, :i32, 1
pool_def :node, max: 2
every_ms 10, :tick
every_ms 10, :fast, context: :interrupt

def tick(out)
  out[0] = Node.alloc
  0
end

def fast
  Node.free(0) if Node.live?(0)
  0
end
