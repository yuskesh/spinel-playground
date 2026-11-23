module Adc
  COUNT = 1
  CH0 = 0
end
module Telemetry
end
module Log
end

# A module this source does not define.
def run(reading, frame, small, shared)
  reading[0] = Adc.latest(Gpio::PIN0)
  0
end
