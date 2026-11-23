# Channels under the two inbound drop reasons (0014 §5): `commands` has depth
# 1, so a second inbound before the consumer runs is a channel_full drop, and
# a 5-byte payload on a size-4 channel is an oversize drop. `echo` copies each
# command out on `replies`.
require "spinel/core"
state :command, :u8, 4
state :reply, :u8, 4
channel :commands, :in, size: 4, depth: 1, uart: true
channel :replies, :out, size: 4, depth: 2, uart: true
every_ms 5, :echo
def echo(command, reply)
  n = Commands.get(command)
  if n > 0
    reply[0] = command[0]
    Replies.put(reply, 1)
  end
  0
end
