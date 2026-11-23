module Adc
end
module Telemetry
end
module Log
end

def run(reading, frame, small, shared)
  Telemetry.put(reading, 1)
  0
end
