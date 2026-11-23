# declaration: a non-literal argument.
require "spinel/core"
PERIOD = 5
state :a, :u32, 1
every_ms PERIOD, :poll
def poll(a)
  0
end
