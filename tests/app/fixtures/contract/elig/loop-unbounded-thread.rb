module Adc
end
module Telemetry
end
module Log
end

def run(reading, frame, small, shared)
  i = 0
  while i != 3
    frame[i] = 1
    i += 1
  end
  0
end
