# tests/app/udp.sh: on a board whose udp_consumer is ocram-ring-v1, refused at step 1 (big).
require "spinel/core"
state :m, :u8, 64
channel :a, :out, size: 1292, depth: 128, udp: true
every_ms 5, :tick
def tick(m)
  0
end
