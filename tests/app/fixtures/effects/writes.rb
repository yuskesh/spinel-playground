module Adc
end
module Telemetry
end

def bump(buf, i)
  buf[i] = buf[i] + 1
  0
end

def peek(buf, i)
  buf[i]
end

def run(direct, viahelper, viaextern, ro)
  direct[0] = Adc.latest(0)
  bump(viahelper, 1)
  Telemetry.get(viaextern)
  peek(ro, 0)
  0
end
