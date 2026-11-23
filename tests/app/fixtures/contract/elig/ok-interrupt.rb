module Adc
end
module Telemetry
end
module Log
end

def run(reading, frame, small, shared)
  v = Adc.latest(0)
  reading[0] = v
  frame[0] = v & 0xff
  Telemetry.put(frame, 1)
  0
end
