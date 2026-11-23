module Adc
  COUNT = 1
  CH0 = "zero"
end
module Telemetry
end
module Log
end

# A constant in a module body that is not an integer literal.
def run(reading, frame, small, shared)
  reading[0] = Adc.latest(Adc::CH0)
  0
end
