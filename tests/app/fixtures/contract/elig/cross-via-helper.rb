module Adc
end
module Telemetry
end
module Log
end

def h(buf)
  Telemetry.get(buf)
end

def run(reading, frame, small, shared)
  h(shared)
  0
end
