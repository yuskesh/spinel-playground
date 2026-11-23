# A constant past a 32-bit Integer, as a 32-bit body reads it (decision 0019):
# refused, and the diagnostic names the body's 32 bits.
ST_SGN = 0x80000000

def tick(state)
  state[0] = ST_SGN - state[0]
  0
end
