module Adc
end
module Telemetry
end
module Log
end

def run(reading, frame, small, shared)
  Telemetry.get(shared)
  0
end
