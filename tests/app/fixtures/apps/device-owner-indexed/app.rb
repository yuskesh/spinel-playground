# Admitted: button_0 and button_1 are distinct devicetree nodes, so one
# context on each is one owner per device. The index at each site is a board
# constant (0014 D5), whose value reaches the owner check through the
# report's const_args exactly as a literal's does.
require "spinel/core"
state :a, :i32, 1
state :b, :i32, 1
every_us 1000, :fast, context: :interrupt
every_ms 5, :slow
def fast(a)
  a[0] = Button.read(Button::SW0)
  0
end
def slow(b)
  b[0] = Button.read(Button::SW1)
  0
end
