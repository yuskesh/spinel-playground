module Adc
end
module Telemetry
end
module Log
end

def run(reading, frame, small, shared)
  Adc.latest(0, 1)
  0
end
