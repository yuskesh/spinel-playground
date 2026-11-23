module Adc
  COUNT = 1
  CH0 = 0
end
module Telemetry
end
module Log
end

# A path of more than one level: refused, `Mod::NAME` is the whole notation.
def run(reading, frame, small, shared)
  reading[0] = Adc.latest(Adc::Ch::ZERO)
  0
end
