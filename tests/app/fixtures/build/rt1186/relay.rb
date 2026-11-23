# tests/app/fixtures/build/rt1186/relay.rb -- tests/app/build.sh 2f: the M33
# end of the console contract as examples/doom/core/board/companion.rb relays
# it (decision 0027 stage 2), its body verbatim: it declares the uart: channel,
# so it owns the console, and puts each line it takes from `console` on `vcom`.
require "spinel/core"

state :rx_tic, :u32, 1
state :rx_len, :u8, 1
state :rx_text, :u8, 119
state :held, :i32, 1      # the length of the line vcom has not taken yet, or 0
state :written, :i32, 1
state :malformed, :i32, 1
channel :vcom, :out, size: 119, depth: 32, uart: true
channel :console, contract: "channels/console.channel"
every_ms 1, :relay

def relay(rx_tic, rx_len, rx_text, held, written, malformed)
  if held[0] > 0
    return 0 if Vcom.put(rx_text, held[0]) == 0
    held[0] = 0
    written[0] = core_w32_add(written[0], 1)
  end
  k = 0
  while k < 4
    return 0 if Console.get(rx_tic, rx_len, rx_text) == 0
    n = rx_len[0]
    if n == 0 || n > 119
      malformed[0] = core_w32_add(malformed[0], 1)
    elsif Vcom.put(rx_text, n) == 0
      held[0] = n
      return 0
    else
      written[0] = core_w32_add(written[0], 1)
    end
    k += 1
  end
  0
end
