# An application that declares its OWN member on a board module, and names
# that module's board constant (0014 D5). The packed root must still carry
# Led's constants: the application declares a member, never the board's
# constants, so dropping them would leave Led::LED0 unresolvable in exactly
# the applications that extend Led.
require "spinel/core"
state :level, :u32, 1
every_ms 5, :blink
module Led
  core_extern :toggle, params: {index: :u32}, returns: :i32, isr_ok: true,
              bound: "iterations 1", provider: "drivers/led_extra.c"
end
def blink(level)
  level[0] = level[0] + 1
  Led.set(Led::LED0, level[0] & 1)
  Led.toggle(Led::LED0)
  0
end
