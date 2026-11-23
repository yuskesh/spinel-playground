# The accepted multi-context application: an interrupt entry samples the ADC
# into a cross-context state; a thread entry reads it, drives an LED and
# reports over a channel; a second thread entry consumes commands.
require "spinel/core"
require "spinel/net"
state :reading, :i32, 1
state :frame, :u8, 16
state :command, :u8, 8
state :level, :u32, 1
channel :telemetry, :out, size: 16, depth: 4, uart: true
channel :commands, :in, size: 8, depth: 2, uart: true
every_us 1000, :sample, context: :interrupt
every_ms 5, :report
every_ms 10, :command_poll

def sample(reading)
  reading[0] = Adc.latest(0)
  0
end

def report(reading, frame, level)
  v = reading[0]
  n = put_i32(frame, 0, v)
  n = put_u8(frame, n, level[0] & 0xff)
  Led.set(0, level[0] & 0xff)
  Telemetry.put(frame, n)
  0
end

def command_poll(command, level)
  n = Commands.get(command)
  if n > 0
    level[0] = command[0]
  end
  0
end
