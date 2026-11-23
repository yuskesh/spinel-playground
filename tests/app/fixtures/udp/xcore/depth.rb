# tests/app/udp.sh: on a board whose udp_consumer is ocram-ring-v1, refused at step 1 (depth).
require "spinel/core"
state :m, :u8, 64
channel :a, :out, size: 64, depth: 6, udp: true
every_ms 5, :tick
def tick(m)
  0
end
