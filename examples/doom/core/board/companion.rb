# examples/doom/core/board/companion.rb — the M33 companion of pair.rb
# (decision 0027): a CORE application on the FRDM-IMXRT1186's Cortex-M33,
# built in the same sysbuild as the M7's pair.rb
# (`spinel-core-app build --companion`). Its glue writes the region's header
# before it releases the M7.
#
# It relays pair.rb's console (stage 2, the first user): it declares the one
# uart: channel of the pair, so it owns LPUART1, and at each release it
# takes up to 4 lines from the `console` channel of channels/console.channel
# and puts each on its own `vcom` channel, declared first so that its frames
# are channel 0, as the lane reads them. A line `vcom` cannot take is held
# and put first at the next release; a line whose length is 0 or above the
# text's 119 bytes is dropped and counted. The counts close after a drained
# run as taken = written + malformed + held (decision 0027, Stage 2's
# choices); the lane reads them with the debugger.
#
# Since decision 0028 the relay is released by the console channel's
# doorbell (`wake: :console`): the M7's put rings MU1's GIR0 when the relay
# waits on an empty ring, and the relay runs then; its period, 10 ms (the
# owner's, Q3), is the time-out of a doorbell that never comes.
require "spinel/core"

state :rx_tic, :u32, 1
state :rx_len, :u8, 1
state :rx_text, :u8, 119
state :held, :i32, 1      # the length of the line vcom has not taken yet, or 0
state :written, :i32, 1
state :malformed, :i32, 1
channel :vcom, :out, size: 119, depth: 32, uart: true
channel :console, contract: "channels/console.channel"
every_ms 10, :relay, wake: :console

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
