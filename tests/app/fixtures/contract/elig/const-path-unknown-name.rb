module Adc
  COUNT = 1
  CH0 = 0
end
module Telemetry
end
module Log
end

# A module that is here, a name it does not carry.
def run(reading, frame, small, shared)
  reading[0] = Adc.latest(Adc::NOPE)
  0
end
