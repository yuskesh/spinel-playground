module Adc
  core_extern :latest, params: {ch: :u32}, returns: :i32, guards: ["ch < 1 else bounds"]
end
module Telemetry
end
module Log
end

def run(reading, frame, small, shared)
  reading[0] = Adc.latest(0)
  0
end
