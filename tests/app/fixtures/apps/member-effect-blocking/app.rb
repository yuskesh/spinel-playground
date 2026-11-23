# member-effect: Flash.erase's instance is blocking, and Led 1 is of unknown
# blocking; realtime admits neither, in any context.
require "spinel/core"
state :a, :u32, 1
every_ms 5, :slow
def slow(a)
  Led.set(1, a[0])
  Flash.erase(0)
  0
end
