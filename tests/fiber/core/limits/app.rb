# The i32 limits cross a suspension in a frame field and come back unchanged.
require "spinel/core"
require "spinel/net"
state :frame, :u8, 4
state :turn, :i32, 1
channel :telemetry, :out, size: 4, depth: 4, uart: true
fiber_def :keeper, max: 1
every_ms 10, :tick

def keeper(v)
  Fiber.yield 0
  v
end

def tick(frame, turn)
  unless Keeper.alive?(0)
    if turn[0] == 0
      Keeper.start(0, 2147483647)
    else
      Keeper.start(0, -2147483647 - 1)
    end
    turn[0] = 1 - turn[0]
  end
  n = put_i32(frame, 0, Keeper.resume(0, 0))
  Telemetry.put(frame, n)
  0
end
