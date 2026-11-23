# A reader fiber steps once per release; each value goes out as a frame.
require "spinel/core"
require "spinel/net"
state :frame, :u8, 4
channel :telemetry, :out, size: 4, depth: 4, uart: true
fiber_def :reader, max: 2
every_ms 10, :tick

def reader(limit)
  i = 0
  while i < limit
    got = Fiber.yield i * 10
    i += got
  end
  limit
end

def tick(frame)
  Reader.start(1, 3) unless Reader.alive?(1)
  v = Reader.resume(1, 1)
  n = put_i32(frame, 0, v)
  Telemetry.put(frame, n)
  0
end
