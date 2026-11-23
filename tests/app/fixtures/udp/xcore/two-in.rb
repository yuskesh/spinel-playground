# tests/app/udp.sh: on a board whose udp_consumer is ocram-ring-v1, refused at step 1 (two-in).
require "spinel/core"
state :m, :u8, 64
channel :a, :in, size: 17, depth: 16, udp: true
channel :b, :in, size: 17, depth: 16, udp: true
every_ms 5, :tick
def tick(m)
  0
end
