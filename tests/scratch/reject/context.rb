require "spinel/core"
require "spinel/net"
state :frame, :u8, 4
channel :telemetry, :out, size: 4, depth: 4, uart: true
scratch 64, context: :idle
every_ms 10, :tick

def tick(frame)
  a = Core::Buffer.i32(1, 7)
  n = put_i32(frame, 0, a[0])
  Telemetry.put(frame, n)
  0
end
