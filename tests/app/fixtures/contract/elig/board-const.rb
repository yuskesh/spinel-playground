module Adc
  COUNT = 1
  CH0 = 0
end
module Telemetry
end
module Log
end

# DECISION 0014 D5: the board package's notation. `Adc::COUNT` bounds the loop
# and `Adc::CH0` is the extern's index argument, whose value const_args carries.
def run(reading, frame, small, shared)
  i = 0
  while i < Adc::COUNT
    reading[0] = Adc.latest(Adc::CH0)
    i += 1
  end
  0
end
