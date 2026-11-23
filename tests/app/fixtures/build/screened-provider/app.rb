# The screened provider control of Task 10: the same application as
# own-provider, with a provider that sleeps. The screen of 0014 §6 refuses
# it at step 5, naming the blocking symbol.
require "spinel/core"
state :reading, :i32, 1
every_ms 5, :poll
module Sensor
  core_extern :read, params: {ch: :u32}, returns: :i32, isr_ok: true,
              bound: "iterations 1", provider: "drivers/sleepy.c"
end
def poll(reading)
  reading[0] = Sensor.read(0)
  0
end
