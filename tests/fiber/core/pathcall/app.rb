# Decision 0045, the review: calls whose receiver is a constant path,
# inside a fiber_def body and outside it, are not buffers. spinel-fiber-core
# reads each such receiver's last name (prism 0.19 has no #name there) and
# rewrites the application; this one is only rewritten, not admitted.
require "spinel/core"
require "spinel/net"
state :frame, :u8, 4
channel :telemetry, :out, size: 4, depth: 4, uart: true
fiber_def :reader, max: 1
every_ms 10, :tick

def reader(limit)
  i = 0
  while i < limit
    got = Fiber.yield Board::Gain.scale(i)
    i += got
  end
  limit
end

def tick(frame)
  Reader.start(0, 3) unless Reader.alive?(0)
  v = Reader.resume(0, 1)
  n = put_i32(frame, 0, ::Board::Gain.scale(v))
  ::Telemetry.put(frame, n)
  0
end
