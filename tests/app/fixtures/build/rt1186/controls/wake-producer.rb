# tests/app/build.sh 2g control: producer.rb woken by `console`, which this
# core produces: the doorbell wakes the consumer, refused at step 1 (decision 0028)
require "spinel/core"
state :line, :u8, 119
state :count, :i32, 1
channel :console, contract: "../channels/console.channel"
every_ms 100, :tick, wake: :console

def tick(line, count)
  count[0] = core_w32_add(count[0], 1)
  n = put_dec(line, 0, count[0])
  Console.put(count[0], n, line)
  0
end
