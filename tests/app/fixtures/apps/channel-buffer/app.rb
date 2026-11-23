# channel-buffer: `command` holds 4 bytes and the channel's size is 8, so
# `get` is refused at build by the extern's static requirement.
require "spinel/core"
state :command, :u8, 4
channel :commands, :in, size: 8, depth: 2, uart: true
every_ms 5, :poll
def poll(command)
  Commands.get(command)
  0
end
