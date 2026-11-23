module Adc
end

def twice(out)
  i = 0
  while i < 3
    out[i] = Adc.latest(0)
    i += 1
  end
  0
end

def c_seq(out)
  out[0] = Adc.latest(0)
  out[1] = Adc.latest(0)
  0
end

def c_loops(out)
  i = 0
  while i < 2
    out[i] = Adc.latest(0)
    i += 1
  end
  j = 0
  while j < 3
    out[j] = Adc.latest(0)
    j += 1
  end
  0
end

def c_helper(out)
  twice(out)
  twice(out)
  0
end

def c_cond(out)
  if out[0] > 0
    out[1] = Adc.latest(0)
  else
    out[2] = Adc.latest(0)
  end
  0
end

# 0014 D5: the board package's constants live in their module. Written here,
# at the end, so the entries above keep the line numbers the call-site checks
# of tests/app/effects.sh name.
module Adc
  CH0 = 0
  CH1 = 1
end

def c_const(out)
  out[0] = Adc.latest(Adc::CH0)
  out[1] = Adc.latest(Adc::CH1)
  0
end
