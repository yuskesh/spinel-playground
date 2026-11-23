# unknown-member: the board has Adc.latest, not Adc.read.
require "spinel/core"
state :a, :i32, 1
every_ms 5, :poll
def poll(a)
  a[0] = Adc.read(0)
  0
end
