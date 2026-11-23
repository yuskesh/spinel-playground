# guards-in-source: an application's own core_extern has no precondition
# surface; `guards:` belongs to generated declarations only.
require "spinel/core"
state :a, :i32, 1
every_ms 5, :poll
module Sensor
  core_extern :read, params: {ch: :u32}, returns: :i32, isr_ok: true, bound: "iterations 1",
              provider: "drivers/sensor.c", guards: ["ch < 2 else bounds"]
end
def poll(a)
  a[0] = Sensor.read(0)
  0
end
