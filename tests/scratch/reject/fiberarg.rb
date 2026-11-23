require "spinel/core"
require "spinel/net"
state :frame, :u8, 4
channel :telemetry, :out, size: 4, depth: 4, uart: true
scratch 64
fiber_def :reader, max: 1
every_ms 10, :tick

def reader(limit)
  Fiber.yield limit
  limit
end

def tick(frame)
  a = Core::Buffer.i32(2, 3)
  Reader.start(0, a) unless Reader.alive?(0)
  v = Reader.resume(0, 1)
  n = put_i32(frame, 0, v)
  Telemetry.put(frame, n)
  0
end
