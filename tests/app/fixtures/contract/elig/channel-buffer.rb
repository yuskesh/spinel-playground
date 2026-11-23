module Adc
end
module Telemetry
end
module Log
end

def run(reading, frame, small, shared)
  Telemetry.get(small)
  0
end
