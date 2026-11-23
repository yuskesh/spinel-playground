module Adc
end
module Telemetry
end
module Log
end

def put(out, pos, s, n)
  i = 0
  while i < n
    out[pos + i] = s[i]
    i += 1
  end
  pos + n
end

def run(reading, frame, small, shared)
  v = Adc.latest(0)
  reading[0] = v
  n = put(frame, 0, "ok", 2)
  Telemetry.put(frame, n)
  Log.write("boot", 4)
  Telemetry.get(frame)
  0
end
