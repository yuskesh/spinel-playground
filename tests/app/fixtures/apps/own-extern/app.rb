# An application with a core_extern of its own, admitted; the packed root
# turns the declaration into comments, one per line, so the snapshot holds
# no core_extern for the pinned analyser to expand.
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
