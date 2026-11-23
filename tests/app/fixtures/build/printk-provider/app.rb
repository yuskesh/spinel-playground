# The printing provider control: the same application as own-provider, with
# a provider that calls printk. printk is in no screen set, but a provider's
# evidence counts only its own frame, so step 5 refuses a provider that calls
# anything it does not define, naming the call.
require "spinel/core"
state :reading, :i32, 1
every_ms 5, :poll
module Sensor
  core_extern :read, params: {ch: :u32}, returns: :i32, isr_ok: true,
              bound: "iterations 1", provider: "drivers/loud.c"
end
def poll(reading)
  reading[0] = Sensor.read(0)
  0
end
