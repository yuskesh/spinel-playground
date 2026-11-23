module Adc
  COUNT = 1
  CH0 = 0
  CH0 = 1
end
module Telemetry
end
module Log
end

# One name, two values: refused rather than resolved to whichever ran.
def run(reading, frame, small, shared)
  reading[0] = Adc.latest(Adc::CH0)
  0
end
