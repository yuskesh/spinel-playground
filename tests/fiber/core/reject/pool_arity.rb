# Refused: free takes the slot.
require "spinel/core"
state :out, :i32, 1
pool_def :node, max: 2
every_ms 10, :tick

def tick(out)
  Node.free
  0
end
