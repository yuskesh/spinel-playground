# device-owner: LED 0 is one device, reached from both contexts.
require "spinel/core"
state :a, :u32, 1
state :b, :u32, 1
every_us 1000, :fast, context: :interrupt
every_ms 5, :slow
def fast(a)
  Led.set(0, a[0])
  0
end
def slow(b)
  Led.set(0, b[0])
  0
end
