# Refused: pool_def needs max: with a positive integer literal.
require "spinel/core"
state :out, :i32, 1
pool_def :node, max: 0
every_ms 10, :tick

def tick(out)
  out[0] = 0
  0
end
