# Misuse: next after the last value (the second release). It is BOUNDS, where
# Ruby raises StopIteration (decision 0035, enum_def).
require "spinel/core"
state :out, :i32, 1
state :started, :i32, 1
enum_def :once, max: 1
every_ms 10, :tick

def once(y, v)
  y.yield v
end

def tick(out, started)
  if started[0] == 0
    Once.start(0, 7)
    started[0] = 1
  end
  out[0] = Once.next(0)
  0
end
