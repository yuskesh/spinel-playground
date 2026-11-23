# declaration: one entry named by two triggers.
require "spinel/core"
state :a, :u32, 1
every_ms 5, :poll
every_ms 7, :poll
def poll(a)
  0
end
