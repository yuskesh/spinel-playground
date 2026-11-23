# The M7 end of the console contract (decision 0027 stage 2;
# tests/app/build.sh 2f): every 100 ms a line of the count into the channel,
# its tic the same count. It declares no uart: channel, so the companion
# owns the console.
require "spinel/core"
state :line, :u8, 119
state :count, :i32, 1
channel :console, contract: "channels/console.channel"
every_ms 100, :tick

def tick(line, count)
  count[0] = core_w32_add(count[0], 1)
  n = put_dec(line, 0, count[0])
  Console.put(count[0], n, line)
  0
end
