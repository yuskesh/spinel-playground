# shared-writer: `counter` is cross-context, and both contexts write it.
require "spinel/core"
state :counter, :u32, 1
every_us 1000, :tick, context: :interrupt
every_ms 5, :poll
def tick(counter)
  counter[0] = counter[0] + 1
  0
end
def poll(counter)
  counter[0] = 0
  0
end
