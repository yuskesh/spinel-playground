require "spinel/core"
require "spinel/net"
state :frame, :u8, 4
channel :telemetry, :out, size: 4, depth: 4, uart: true
scratch 64
every_ms 10, :tick

def tick(frame)
  a = Core::Buffer.i32(4, 0)
  Telemetry.put(a, 4)
  0
end
