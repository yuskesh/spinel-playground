require "spinel/core"
require "spinel/net"
state :frame, :u8, 4
channel :telemetry, :out, size: 4, depth: 4, uart: true
scratch 64
fiber_def :reader, max: 1
every_ms 10, :tick

def reader(limit)
  a = Core::Buffer.i32(2, 0)
  Fiber.yield a[0]
  limit
end

def tick(frame)
  Reader.start(0, 3) unless Reader.alive?(0)
  v = Reader.resume(0, 1)
  n = put_i32(frame, 0, v)
  Telemetry.put(frame, n)
  0
end
