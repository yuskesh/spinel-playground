# A context failure: `fast` indexes past its state on release 3 (BOUNDS);
# its context stops, its remaining releases are CANCEL records naming the
# FAIL, and the thread entry keeps running.
require "spinel/core"
state :samples, :u32, 2
state :ticks, :u32, 1
every_us 1000, :fast, context: :interrupt
every_ms 2, :slow
def fast(samples)
  n = samples[0] + 1
  samples[0] = n
  samples[n] = 0
  0
end
def slow(ticks)
  ticks[0] = ticks[0] + 1
  0
end
