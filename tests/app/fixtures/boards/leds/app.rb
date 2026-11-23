# An application over the generated board package: it polls button 0 and
# blinks LED 0, naming both by the board's alias constants (sw0, led0), which
# both real boards and the mixed synthetic board provide.
require "spinel/core"
state :level, :u32, 1
state :pressed, :i32, 1
every_ms 5, :blink
def blink(level, pressed)
  pressed[0] = Button.read(Button::SW0)
  level[0] = level[0] + 1
  Led.set(Led::LED0, level[0] & 1)
  0
end
