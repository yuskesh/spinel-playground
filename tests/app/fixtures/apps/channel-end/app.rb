# channel-end: the producer end of `telemetry` is used from both contexts.
require "spinel/core"
state :frame, :u8, 4
state :other, :u8, 4
channel :telemetry, :out, size: 4, depth: 2, uart: true
every_us 1000, :fast, context: :interrupt
every_ms 5, :slow
def fast(frame)
  frame[0] = 1
  Telemetry.put(frame, 1)
  0
end
def slow(other)
  other[0] = 2
  Telemetry.put(other, 1)
  0
end
