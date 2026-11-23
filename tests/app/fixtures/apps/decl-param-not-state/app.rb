# declaration: an entry parameter that names no state.
require "spinel/core"
state :a, :u32, 1
every_ms 5, :poll
def poll(a, b)
  0
end
