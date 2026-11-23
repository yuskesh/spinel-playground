# The acceptance sample of decision 0014 (Validation, "Acceptance on
# mps2/an521 in QEMU"): one timer-driven interrupt entry and two thread
# entries, cross-context state, one inbound and one outbound UART channel,
# Led (real), Button (polled, through gpio-emul) and Adc (through adc-emul).
# It names board members by the alias constants both boards provide.
require "spinel/core"
require "spinel/net"
state :reading, :i32, 1
state :pressed, :i32, 1
state :frame, :u8, 16
state :command, :u8, 8
state :level, :u32, 1
channel :telemetry, :out, size: 16, depth: 4, uart: true
channel :commands, :in, size: 8, depth: 2, uart: true
every_us 1000, :sample, context: :interrupt
every_ms 5, :report
every_ms 10, :command_poll

# interrupt context: the latest ADC reading, published to the thread context
def sample(reading)
  reading[0] = Adc.latest(Adc::CH0)
  0
end

# thread context: reads the cross state and the button, drives the LED,
# reports over the channel
def report(reading, pressed, frame, level)
  pressed[0] = Button.read(Button::SW0)
  v = reading[0]
  n = put_i32(frame, 0, v)
  n = put_u8(frame, n, pressed[0] & 0xff)
  n = put_u8(frame, n, level[0] & 0xff)
  Led.set(Led::LED0, level[0] & 1)
  Telemetry.put(frame, n)
  0
end

# thread context: consumes commands, the first byte sets the level
def command_poll(command, level)
  n = Commands.get(command)
  if n > 0
    level[0] = command[0]
  end
  0
end
