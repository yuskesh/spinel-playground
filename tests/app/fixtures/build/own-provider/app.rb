# The accepted application provider control of Task 10: an application with
# a core_extern of its own whose provider calls nothing of Zephyr. The build
# compiles, screens and measures drivers/sensor.c, links it, and reports its
# frame in the evidence and in build.json.
require "spinel/core"
state :reading, :i32, 1
every_ms 5, :poll
module Sensor
  core_extern :read, params: {ch: :u32}, returns: :i32, isr_ok: true,
              bound: "iterations 1", provider: "drivers/sensor.c"
end
def poll(reading)
  reading[0] = Sensor.read(0)
  0
end
