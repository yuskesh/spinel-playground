# An enumerator steps once per release; each value goes out as a frame, -1
# marks the end, and the slot restarts after it (decision 0035, enum_def).
require "spinel/core"
require "spinel/net"
state :frame, :u8, 4
channel :telemetry, :out, size: 4, depth: 4, uart: true
enum_def :evens, max: 1
every_ms 10, :tick

def evens(y, limit)
  i = 0
  while i < limit
    y << i
    i += 2
  end
end

def tick(frame)
  Evens.start(0, 5) unless Evens.alive?(0)
  v = -1
  if Evens.next?(0)
    v = Evens.peek(0) * 100 + Evens.next(0)
  end
  n = put_i32(frame, 0, v)
  Telemetry.put(frame, n)
  0
end
