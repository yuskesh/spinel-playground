# spinel: int64
# The two-channel application of tests/app/channel.sh: `telemetry` out,
# `commands` in. The entries exercise the ring through the generated modules
# (the guards, a put, a get) and the byte helpers on a fixed table; the
# harnesses call the natively built entries.
require "spinel/core"
require "spinel/net"
state :frame, :u8, 16
state :n, :u32, 1
state :command, :u8, 8
state :got, :i32, 1
state :bytes, :u8, 32
state :tag, :u8, 4
channel :telemetry, :out, size: 16, depth: 4, uart: true
channel :commands, :in, size: 8, depth: 2, uart: true
every_ms 5, :report
every_ms 5, :send_n
every_ms 5, :poll
every_ms 5, :fill

# puts one 5-byte message: 0x01 0x02 0x03 0x04 0x05
def report(frame)
  frame[0] = 1
  frame[1] = 2
  frame[2] = 3
  frame[3] = 4
  frame[4] = 5
  Telemetry.put(frame, 5)
  0
end

# puts n[0] bytes: the guards decide (0 -> ARGUMENT, 17 -> BOUNDS)
def send_n(frame, n)
  Telemetry.put(frame, n[0])
  0
end

# gets one command into `command`, its length into got[0]
def poll(command, got)
  got[0] = Commands.get(command)
  0
end

# the byte helpers on a fixed table, into `bytes`
def fill(bytes, tag)
  tag[0] = 84
  tag[1] = 65
  tag[2] = 71
  tag[3] = 33
  pos = put_u8(bytes, 0, 0xab)
  pos = put_u16(bytes, pos, 0x1234)
  pos = put_i32(bytes, pos, -2)
  pos = put_dec(bytes, pos, -12345)
  pos = put_dec(bytes, pos, 0)
  pos = put_dec(bytes, pos, 4294967296)
  pos = put_str(bytes, pos, tag, 4)
  pos = put_u8(bytes, pos, pos)
  0
end
