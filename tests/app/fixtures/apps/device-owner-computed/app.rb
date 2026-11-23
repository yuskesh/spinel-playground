# device-owner: `slow` reads a button whose index is computed, which reaches
# every Button instance, including button_0, which `fast` owns.
require "spinel/core"
state :a, :i32, 1
state :b, :i32, 1
state :which, :u32, 1
every_us 1000, :fast, context: :interrupt
every_ms 5, :slow
def fast(a)
  a[0] = Button.read(0)
  0
end
def slow(b, which)
  b[0] = Button.read(which[0])
  0
end
