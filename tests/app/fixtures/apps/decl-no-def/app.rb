# declaration: a trigger naming no top-level def.
require "spinel/core"
state :a, :u32, 1
every_ms 5, :poll
def other(a)
  0
end
