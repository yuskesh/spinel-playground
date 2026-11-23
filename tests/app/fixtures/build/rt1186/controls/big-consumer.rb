# tests/app/build.sh 2f, control 3: the consumer over controls/big.channel
require "spinel/core"
state :rx_tic, :u32, 1
state :rx_len, :u8, 1
state :rx_text, :u8, 119
state :got, :i32, 1
channel :console, contract: "big.channel"
every_ms 1, :relay

def relay(rx_tic, rx_len, rx_text, got)
  if Console.get(rx_tic, rx_len, rx_text) == 1
    got[0] = core_w32_add(got[0], 1)
  end
  0
end
