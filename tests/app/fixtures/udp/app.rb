# The application of tests/app/udp.sh: a UART channel beside two udp:
# channels, so the transport thread drains both kinds. The network file the
# suite writes sends `frames` to the loopback and switches `spare` off (port
# 0). The harness calls the rings and the transport directly; the entry only
# makes the declarations an application.
require "spinel/core"
state :msg, :u8, 64
channel :console, :out, size: 16, depth: 4, uart: true
channel :frames, :out, size: 64, depth: 4, udp: true
channel :spare, :out, size: 8, depth: 2, udp: true
every_ms 5, :tick

def tick(msg)
  msg[0] = 1
  Console.put(msg, 1)
  Frames.put(msg, 64)
  Spare.put(msg, 8)
  0
end
