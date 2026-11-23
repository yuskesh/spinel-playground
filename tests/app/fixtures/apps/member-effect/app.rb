# member-effect: Pwm.set is not isr_ok, and `fast` runs in interrupt context.
require "spinel/core"
state :a, :u32, 1
every_us 1000, :fast, context: :interrupt
def fast(a)
  Pwm.set(0, a[0])
  0
end
