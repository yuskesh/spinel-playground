# tests/app/udp.sh: a udp: :out channel and a udp: :in one (decision 0025),
# for the network file's inbound line and the inbound ring's get. The entry
# only makes the declarations an application.
require "spinel/core"
state :msg, :u8, 64
state :keys, :u8, 17
channel :frames, :out, size: 64, depth: 4, udp: true
channel :keys, :in, size: 17, depth: 16, udp: true
every_ms 5, :tick

def tick(msg, keys)
  msg[0] = Keys.get(keys)
  Frames.put(msg, 64)
  0
end
