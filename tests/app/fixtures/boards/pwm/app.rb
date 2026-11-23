# Resolution: Pwm exists on the mixed synthetic board and on no real board,
# so this resolves there and is unknown-member on mps2/an521.
require "spinel/core"
state :duty, :u32, 1
every_ms 5, :fade
def fade(duty)
  duty[0] = duty[0] + 1000
  Pwm.set(Pwm::PWM_LED0, duty[0])
  0
end
