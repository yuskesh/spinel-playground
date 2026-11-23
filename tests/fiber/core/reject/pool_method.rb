# Refused: a method the pool module does not have.
require "spinel/core"
state :out, :i32, 1
pool_def :node, max: 2
every_ms 10, :tick

def tick(out)
  out[0] = Node.count
  0
end
