# Exhaustion: a pool of 2 slots, one alloc a release and no free. The third
# release's alloc is CAPACITY (status 4), at the same release on every run.
require "spinel/core"
state :out, :i32, 1
pool_def :node, max: 2
every_ms 10, :tick

def tick(out)
  out[0] = Node.alloc
  0
end
