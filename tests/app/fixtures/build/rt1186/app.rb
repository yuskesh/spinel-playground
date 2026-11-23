# The board build of decision 0021 on FRDM-IMXRT1186's CM33 core: one thread
# entry and an outbound UART channel, over the board's generated package. It
# uses no Adc (the board declares no zephyr,user channels) and no Pwm.
require "spinel/core"
require "spinel/net"
state :line, :u8, 24
state :count, :i32, 1
channel :out, :out, size: 24, depth: 4, uart: true
every_ms 100, :tick

def tick(line, count)
  count[0] = count[0] + 1
  n = put_dec(line, 0, count[0])
  Out.put(line, n)
  0
end
