# tests/app/build.sh 2f, control 2: the producer over controls/ptr.channel, refused
require "spinel/core"
state :line, :u8, 119
state :count, :i32, 1
channel :console, contract: "ptr.channel"
every_ms 100, :tick

def tick(line, count)
  count[0] = core_w32_add(count[0], 1)
  n = put_dec(line, 0, count[0])
  Console.put(count[0], n, line)
  0
end
