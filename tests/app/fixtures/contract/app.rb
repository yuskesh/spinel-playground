module Adc
end
module Telemetry
end

def fill(out, v)
  out[0] = v & 0xff
  1
end

def sample(reading, frame)
  v = Adc.latest(0)
  reading[0] = v
  n = fill(frame, v)
  Telemetry.put(frame, n)
  0
end
