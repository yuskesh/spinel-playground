# declaration: a `udp:` endpoint written in the source is refused; it comes from the network file (--net, decision 0014 §5).
require "spinel/core"
state :a, :u8, 4
channel :telemetry, :out, size: 4, depth: 2, udp: "192.0.2.1:9000"
every_ms 5, :poll
def poll(a)
  0
end
