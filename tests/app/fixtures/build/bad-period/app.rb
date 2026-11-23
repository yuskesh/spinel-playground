# The unrepresentable period control of Task 10: 150 us is not a multiple
# of the 100 us tick (CONFIG_SYS_CLOCK_TICKS_PER_SEC=10000); step 1 refuses
# it, naming the rate.
require "spinel/core"
state :count, :u32, 1
every_us 150, :tick
def tick(count)
  count[0] = count[0] + 1
  0
end
